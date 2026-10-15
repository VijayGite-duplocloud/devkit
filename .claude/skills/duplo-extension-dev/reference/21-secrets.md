# 21 — Secrets in Spec/Result fields (passwords, API tokens, keys)

A resource's `Spec`/`Result` is plain C# — nothing stops an extension author from adding
`public string? Password { get; set; }` the same way they'd add `public string? Region { get; set; }`.
Treated as an ordinary field, that value is: stored in Mongo in plaintext, echoed back in full on every
GET/List/Create/Update/PATCH response, **and** written in plaintext into `shared/<subtype>.json` — the
file the LLM provisioning agent `Read`s into its own conversation. The attributes and recipe below close
all three, plus the on-screen and ask-AI leaks that follow from them. Worked end-to-end:
[`samples/secret-field`](../../../../samples/secret-field).

## First question: does this even belong on your Spec?

| The secret is… | Use |
|---|---|
| Credentials for an **external system** your extension calls (a SaaS API, a cloud account) | A **Provider/Credential/Scope** ([07-scope-credentials](07-scope-credentials.md)) — `spec.ScopeIds`, not a raw field. Already encrypted at rest, already kept out of the agent's main spec file (it lands in `other_scopes/<name>.json`, which your skill reads with `jq`), already excluded from every response. Nothing further to do. |
| An **inherent attribute of the resource itself** — a password/token the user is choosing *for the thing you're creating* (a DB master password, a service-account token you mint) | There is no Scope for this — it's genuinely part of the resource's own Spec/Result. Use the `[SecretValue]`/`[AgentSecretValue]` pattern below. |

If you're unsure which one you have: would a different, unrelated resource in the same workspace ever
reuse this exact credential? If yes, it's a Scope. If the value only ever makes sense attached to this one
resource, it's a Spec/Result field.

## The four layers

All four types below ship in the SDK feed today (`Duplo.Ai.Common`, `Duplo.Ai.DataManagement`) — nothing
here needs a host/SDK change. The first two are genuinely automatic; the other two are a recipe you copy.

| Layer | Attribute / type | What it does | Automatic? |
|---|---|---|---|
| 1. Response exclusion | `[SecretValue(ExcludeFromResponse = true)]` (`Duplo.Ai.Common.Attributes`) | Drops the property from **every** controller JSON response — GET, List, and the entity echoed by Create/Update/PATCH. Scoped to the response serializer only; model binding, BSON persistence, and the agent-spec serializer are untouched. | **Yes** — add the attribute, nothing else. |
| 2. Agent-spec exclusion | `[AgentSecretValue]` (`Duplo.Ai.Common.Attributes`) | Strips the property out of `shared/<subtype>.json` (what the agent `Read`s) and writes it instead to a sibling `shared/<subtype>.secrets.json`. That sibling file is permanently blocked from the ticket-files API (upload/download/list all refuse it) — the only way to it is your skill reading it directly on disk with `jq`. | **Yes**, reflection-driven over your `TSpec` — add the attribute. The *skill* side (reading the sibling file correctly) is on you — see below. |
| 3. At-rest encryption | `IMongoEncryptionProvider` (`Duplo.Ai.DataManagement.Encryption`) — `EncryptAsync`/`DecryptAsync`/`IsEncryptedAsync` | Encrypts the plaintext before it hits Mongo. | **No** — inject it into your own entity hooks and call it explicitly. Recipe below. |
| 4. Streamed-output backstop | `ISecretRedactionService` (`Duplo.Ai.Common.Utilities`) — `AddSecret(value)` | Once a plaintext value is registered, it's scrubbed to `[REDACTED]` everywhere it later appears in the agent's streamed ticket-chat output — a safety net if a skill ever echoes something it shouldn't. | **No** — call `AddSecret` yourself, right after you decrypt. |

Plus a **reveal endpoint** (layer 5): nothing in the base `ResourcesController<T,TSpec,TResult>` exposes a
decrypted value back to a caller — every resource that needs one (a user reconnecting to a DB with its
original password, say) hand-writes a dedicated, separately-gated endpoint. No generic helper exists;
copy the recipe below.

**Default to marking a field with both `[SecretValue(ExcludeFromResponse = true)]` AND
`[AgentSecretValue]` together.** The only reason to omit `[AgentSecretValue]` is a skill that has a
specific, deliberate need to read the plaintext straight out of the main spec file — and if you do that,
say why in a comment next to the property, the same way you'd document any other deviation from the safe
default.

## The recipe (entity hooks)

Mirrors the platform's own first-party pattern (used identically by three independent resource types
already). On your entity's hooks class (`ResourceHooksBase<TResource,TSpec,TResult>` or
`DefaultEntityHooks<TResource>`):

```csharp
public class MyResourceHooks : ResourceHooksBase<MyResource, MyResourceSpec, MyResourceResult>
{
    private readonly IMongoEncryptionProvider _encryption;
    private readonly ISecretRedactionService _redaction;

    public MyResourceHooks(ILogger<MyResourceHooks> logger, IServiceProvider serviceProvider,
        IMongoEncryptionProvider encryption, ISecretRedactionService redaction)
        : base(logger, serviceProvider)
    {
        _encryption = encryption;
        _redaction = redaction;
    }

    public override async Task OnPreCreateAsync(MyResource entity, CancellationToken ct)
    {
        await base.OnPreCreateAsync(entity, ct);
        await EncryptPasswordAsync(entity, existing: null, ct);
    }

    public override async Task OnPreUpdateAsync(MyResource existing, MyResource updated, CancellationToken ct)
    {
        await base.OnPreUpdateAsync(existing, updated, ct);
        await EncryptPasswordAsync(updated, existing, ct);
    }

    // PATCH semantics (see below): absent/null in the incoming spec means "keep what's stored" —
    // never persist null over a real value. Only a genuinely new, non-empty value is encrypted.
    private async Task EncryptPasswordAsync(MyResource entity, MyResource? existing, CancellationToken ct)
    {
        var incoming = entity.Spec?.Password;
        if (string.IsNullOrEmpty(incoming))
        {
            if (entity.Spec != null) entity.Spec.Password = existing?.Spec?.Password; // keep existing ciphertext
            return;
        }
        _redaction.AddSecret(incoming);                 // plaintext still in hand — register before encrypting
        entity.Spec!.Password = await _encryption.EncryptAsync(incoming, ct);
    }

    public override async Task OnPostReadAsync(MyResource entity, CancellationToken ct)
    {
        await base.OnPostReadAsync(entity, ct);
        var stored = entity.Spec?.Password;
        if (string.IsNullOrEmpty(stored)) return;
        if (await _encryption.IsEncryptedAsync(stored, ct))
        {
            var plaintext = await _encryption.DecryptAsync(stored, ct);
            entity.Spec!.Password = plaintext;
            _redaction.AddSecret(plaintext);             // re-register on every read — the registry is in-memory
        }
        // Fails open deliberately: a value that still looks encrypted after a failed decrypt is left as
        // ciphertext rather than thrown — [SecretValue(ExcludeFromResponse=true)] already keeps it out of
        // the response either way, so there's nothing unsafe about leaving it, and throwing here would 500
        // every GET/List. The reveal endpoint below is where a decrypt failure gets surfaced explicitly.
    }
}
```

`entity.Spec.Password` always carries the real ciphertext (or plaintext, mid-request) in C# memory — this
hooks class never blanks it. Keeping it out of responses is handled once, generically, by
`[SecretValue(ExcludeFromResponse = true)]` at the serialization boundary; keeping it out of the agent is
handled once, generically, by `[AgentSecretValue]`. Nothing in your controller or service needs to scrub
anything.

## The reveal endpoint

Only needed when some caller legitimately has to retrieve the real value later (a user reconnecting to a
database with its original password). Gate it with a **named action** ([18-access-control](18-access-control.md)),
never plain CRUD access — revealing a secret is a materially bigger grant than "can read this resource":

```csharp
// duplo-review-exception: secret-returned-to-client
// reason: the user who owns this resource needs the real password to connect to it, and there is no
//   other way to retrieve it. Scoped to this one explicit, separately-permissioned action — never
//   returned from any other endpoint.
[HttpGet("{id}/password")]
[AccessControl(Action = "myresource.secret.read",
    ActionName = "Reveal password", Destructive = true,
    Description = "Decrypts and returns the real password. A materially bigger grant than ordinary read access.")]
public async Task<IActionResult> RevealPassword(string id, CancellationToken ct)
{
    var value = await _service.RevealPasswordAsync(id, ct);   // decrypts; throws KeyNotFoundException / InvalidOperationException
    return Ok(ApiResponse<object>.SuccessResult(new { value }, "Password retrieved"));
}
```

The service method re-reads the entity, checks `IsEncryptedAsync` to detect a stored value that failed to
decrypt (surface that as an explicit error — never hand back ciphertext as if it were real), and returns
the plaintext. See `samples/secret-field` for the full method.

## The skill side — reading the sibling `.secrets.json`

`[AgentSecretValue]` only protects the field if the skill actually reads it from the sibling file instead
of the main one. In your `provision.sh` (or equivalent), extract it with `jq` **immediately before its one
use** — never with the Read tool, never `echo`/`cat` to stdout, never cached across steps:

```bash
if [ -f ./shared/my-resource.secrets.json ]; then
  PASSWORD=$(jq -r '.password // empty' ./shared/my-resource.secrets.json)
else
  PASSWORD=""
fi
[ -z "$PASSWORD" ] && PASSWORD=$(jq -r '.spec.password // empty' ./shared/my-resource.json)  # fallback: unset/cleared
```

The fallback exists so a ticket written by an older build of your extension (before you added
`[AgentSecretValue]`), or a resource with no password set, still resolves correctly either way.

## PATCH semantics — don't let an edit silently wipe the secret

[04-hooks](04-hooks.md) already establishes that `PATCH {id}` replaces `spec` wholesale, so an edit form
must send the **full** spec. For a secret field that's excluded from GET, the edit form has no value to
echo back — so the convention has to be explicit:

- **Key absent, or value `null`/empty** in the incoming spec → keep the currently-stored value unchanged.
- **A non-empty string** → treat it as a real replacement; encrypt and persist it.

There is no way to distinguish "user left it blank because they didn't change it" from "user wants to
clear it" with a bare string, so if your resource genuinely needs a clear action, give it one explicitly
(a checkbox, a separate `ClearPassword: true` flag) rather than overloading empty string.

## Frontend — write-only, never redisplay

`<password-field>` ([14-forms-and-wizards](14-forms-and-wizards.md)) masks the *display*; it does not stop
a naive edit form from re-submitting whatever the GET response contained. Since the field is now excluded
from every GET, there is nothing to pre-populate — build the edit form accordingly:
- **Add form**: an ordinary `<password-field>`, required.
- **Edit form**: show a placeholder (`"•••• — leave blank to keep"`), start the model field `undefined`,
  and only include the key in the PATCH body when the user actually typed something.

## Hard rules

- **Never put a secret in `AdditionalCustomSpec` or `ExtraConfigs`.** These are untyped `BsonDocument` bags
  — attribute-based protection is structurally impossible on a dynamic key, so anything placed there is
  permanently unprotected by every layer above.
- **The frontend's `buildAskAiContext()` ([16-ask-ai](16-ask-ai.md)) is safe by construction** — it reads
  `item.spec`/`item.result` as populated from the same GET response every other view uses, which already
  never carried the real value. The actual risk is the **backend**-created-ticket alternative (16-ask-ai
  §9): a hand-written `GetTicketMetadata()`/`GetTicketTitle()`/`GetProvisioningMessage()` override runs
  server-side with the real, decrypted `entity.Spec`/`entity.Result` in hand — `ExcludeFromResponse` only
  strips a field from HTTP responses, and these methods don't produce one. Never interpolate a marked field
  into any string one of them builds.
- **Worker mode is not exempt** — `entity.Result` written via `SaveProgressAsync` goes through the same
  response serializer, so layer 1 already covers it; just don't log the plaintext in `Logger.Log*` calls
  along the way.
