# Dispatch authentication verification

Audience: maintainer verification.

This record supports the dispatch judgment rules in `.agents/skills/quota-array-dispatch/SKILL.md` and the bounded vendor probe in `bin/fm-vendor-auth-probe.sh`.
It records only facts that must be re-established when a producer or vendor version changes.
Task chronology, incident transcripts, and credential metadata stay in private reports or PR evidence.

Firstmate resolves a candidate's provider family, credential surface, and applicable quota by reading the evidence below and reasoning in the open.
No script maps a model to a provider, a provider to a credential store, or a name prefix to a family, so the facts here are what that reasoning rests on.
Credential paths below are shown with the home directory replaced by `<home>`.

## Quota granularity the judgment depends on

Verified 2026-07-30 against quota-axi 0.1.16.

`quota-axi --json` reports availability at whatever granularity the vendor supplies, and states the vendor's own bounding rule in `quotaSemantics.description`.

```json
{
  "provider": "codex",
  "state": { "status": "fresh", "stale": false },
  "quotaSemantics": {
    "status": "known",
    "description": "Codex base account windows bound every model. Named model windows add bounds for that model; code-review windows describe a separate workload and are not included in model availability.",
    "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 64, "boundedBy": ["weekly"] },
      { "scope": "model:codex_bengalfox", "status": "known", "effectivePercentRemaining": 64, "boundedBy": ["weekly", "model:codex_bengalfox:7d"] }
    ]
  }
}
```

Three properties follow and are load-bearing for dispatch:

- An `all_models` (or `all_products`) scope is real evidence for every model in that provider family, including a model with no window of its own.
- A `model:`-scoped entry is an additional bound for that one model. `model:codex_bengalfox` is the GPT-5.3-Codex-Spark window and bounds nothing else.
- A named-model window can be tighter than the account bound, so it must not be read across models. In the same snapshot Claude reported `all_models` with `effectivePercentRemaining` 10 while `model:fable` reported 4, limited by the `model:fable` window itself. A non-Fable Claude model reads 10, not 4.

`quotaSemantics.status` is `unknown` with no `effectiveAvailability` entries at all for providers whose vendor exposes no window (observed for `cursor` and `copilot`).
`state.authStatus` is present only for some providers (observed for `grok` alone), so its absence is missing evidence, not a credential fault.

## Completion-runway shape the judgment depends on

Verified 2026-07-31 against quota-axi 0.1.17 schema 3.
The command below records the producer shape without persisting account-specific quota values:

```sh
quota-axi --json | jq '{schemaVersion, effectiveAvailabilityFields: ([.providers[]?.quotaSemantics.effectiveAvailability[]? | keys] | unique), runwayFields: ([.providers[]?.quotaSemantics.effectiveAvailability[]?.runway? | select(type == "object") | keys] | unique)}'
```

```json
{
  "schemaVersion": 3,
  "effectiveAvailabilityFields": [
    [
      "boundedBy",
      "effectivePercentRemaining",
      "limitingWindowIds",
      "pace",
      "runway",
      "scope",
      "status"
    ]
  ],
  "runwayFields": [
    [
      "limitingWindowId",
      "projectedExhaustedAt",
      "projectionBasis",
      "projectionConfidence",
      "status",
      "usableRunwaySeconds"
    ],
    [
      "limitingWindowId",
      "projectedExhaustedAt",
      "status",
      "usableRunwaySeconds"
    ]
  ]
}
```

`runway` is nested under each effective-availability scope, so the same provider/model applicability rules govern both effective headroom and runway.
Projection confidence and basis are not present on every known runway, so selection must preserve their absence as uncertainty rather than fabricate them.
The older-schema fallback contract is owned by `quota-array-dispatch`; this evidence does not reinterpret an absent runway or pace field.

## Provider-family counterfactual that this producer schema supports

Verified 2026-07-30 on Pi 0.82.0 and quota-axi 0.1.16.

```sh
pi --list-models terra
```

```text
provider      model          context  max-out  thinking  images
openai-codex  gpt-5.6-terra  272K     128K     yes       yes
```

The Pi catalog is authoritative for Pi model support and reports the provider family in its own column.
For `harness=pi`, `model=openai-codex/gpt-5.6-terra` the catalog establishes the model is supported and belongs to the `openai-codex` family, and the Codex `all_models` scope above supplies fresh, known 64 effective remaining for every model in that family.
No Terra-specific window exists in the snapshot, and `quota-axi auth --json` lists no `pi:openai-codex` source.
Both absences are missing model-level and source-level detail, not contradictory evidence, so this candidate is dispatchable with the model-level uncertainty disclosed.

```sh
pi --list-models gpt-9.9-nonexistent
```

```text
No models matching "gpt-9.9-nonexistent"
```

A listing that reaches the account and returns no row is the authoritative negative that does block a candidate.

## Credential sources are independent per provider

Verified 2026-07-30 against quota-axi 0.1.16.

`quota-axi auth --json` reports each provider's credential sources separately, which is what lets a candidate be scoped to the one surface it actually authenticates through:

```json
[
  { "provider": "claude", "sources": [
      { "source": "oauth-file", "path": "<home>/.claude/.credentials.json", "status": "missing" },
      { "source": "keychain", "status": "available" } ] },
  { "provider": "codex", "sources": [
      { "source": "auth-json", "path": "<home>/.codex/auth.json", "status": "available" },
      { "source": "cli-rpc", "path": "<path-to>/codex", "status": "available" } ] },
  { "provider": "grok", "sources": [
      { "source": "auth-json", "path": "<home>/.grok/auth.json", "status": "available" },
      { "source": "pi:xai", "status": "available" } ] },
  { "provider": "kimi", "sources": [
      { "source": "pi:kimi-coding", "status": "available" },
      { "source": "kimi-code-cli", "status": "expired", "error": "kimi_code_cli_credential_expired" } ] }
]
```

Observed source statuses are `available`, `expired` (with an `error` slug), and `missing`.

- A provider can carry a healthy source beside a missing or expired one, so a provider must not be collapsed to a single status. Claude's `oauth-file` is missing while its keychain source is available, and Kimi's standalone CLI credential is expired while its Pi source is available.
- A `pi:`-prefixed source exists only where Pi holds its own credential for that family (`pi:xai`, `pi:kimi-coding`). Pi's `openai-codex` family has none, because it authenticates through the Codex store that the `codex` provider already lists. A missing `pi:` source is therefore never evidence against a Pi candidate.

Neither this per-source shape nor `state.authStatus` exists before quota-axi 0.1.16.
`bin/fm-bootstrap.sh` enforces the current compatibility floor through `bin/fm-quota-axi-lib.sh`.

Grok also reports `credits.remaining: 0` alongside `percentRemaining: 41` on a healthy account.
That zero is a prepaid balance, not the subscription window, and is never headroom.

## Standalone Grok discovery probe

Verified 2026-07-30 on `grok 0.2.117 (f1c06093089f) [stable]`.

```sh
grok --version
grok models   # stdin closed, single attempt, hard-bounded
```

Observed:

- `grok models` exits `0` and its first stdout line is `You are logged in with grok.com.` for an authenticated session.
- With a home directory holding no Grok credential, the first stdout line is `You are not authenticated.`, also with exit status `0`.
- Because the status is `0` in both cases, the exit status is not a verdict; only the literal first stdout line is examined, and a blank first line does not authenticate.
- `<home>/.grok/auth.json` was byte-identical across the authenticated run (`mtime`, `size`, and mode `0600` unchanged), so the probe is a read in that path.

These discriminator strings are un-owned vendor UI text.
`bin/fm-vendor-auth-probe.sh` pins the verified version, reports `versionVerified=no` when the running CLI differs, and classifies any unrecognized first line as `indeterminate` rather than authenticated.
Re-run the two commands above and update this section and the pinned version together when the vendor CLI changes.

## Codex seats are separate quota scopes

Verified 2026-09-25 on quota-axi 0.1.28, codex-cli, and Pi 0.83.0, against a two-seat Codex team workspace.

A Codex seat's identity comes from the credential store `CODEX_HOME` points at, so one seat's windows are read by pointing the same command at that seat's store:

```sh
quota-axi --provider codex --json                        # the ambient store
CODEX_HOME=~/.codex-selene quota-axi --provider codex --json
```

The two reads returned different windows from the same account and plan in one snapshot:

| Store | `plan` | `five_hour` | `weekly` | `all_models` effective |
|---|---|---|---|---|
| ambient `~/.codex` | team | 0 | 38 | 0 |
| `~/.codex-selene` | team | 100 | 93 | 93 |

Three properties follow and are load-bearing for seat-aware dispatch:

- A seat is its own quota scope.
  One seat's exhausted five-hour window says nothing about another seat's, so a seated candidate's headroom must be read from that seat's own store and never from the ambient one.
- `quota-axi` honors `CODEX_HOME` and needs no seat-specific flag, which is why `bin/fm-codex-seat.sh quota` is a thin per-seat loop over the same producer rather than a new evidence source.
- No credential appears in the report.
  The observed keys are `generatedAt`, `providers`, and `schemaVersion`, and each provider carries `credits`, `label`, `plan`, `provider`, `quotaSemantics`, `source`, `state`, and `windows`.

Pi selects its own store independently of the Codex CLI:

```sh
pi --offline --list-models | grep -c openai-codex                                   # 10
PI_CODING_AGENT_DIR=<empty dir> pi --offline --list-models | grep -c openai-codex   # 0
CODEX_HOME=~/.codex-selene PI_CODING_AGENT_DIR=<empty dir> pi --list-models | grep -c openai-codex   # 0
```

- `PI_CODING_AGENT_DIR` moves Pi's whole agent dir, including its `auth.json`.
  A fresh dir gets a newly created `auth.json` holding exactly `{}` rather than an inherited credential, which is why an empty JSON object must not be read as a completed sign-in.
- Pi 0.83.0 does NOT bootstrap an `openai-codex` credential from `CODEX_HOME`, so pointing Pi at a seat requires that seat's own Pi login (`/login` in an interactive session, per Pi's `docs/providers.md` "Subscriptions").
  This is why a seat's two stores are separate and why no token is ever copied between them: each consumer refreshes its own rotating OAuth token.

Re-run the commands above and update this section when either vendor CLI changes.

## Regression coverage

`tests/fm-vendor-auth-probe.test.sh` drives the real script against a fake vendor CLI that records every invocation's argv and anything readable on stdin.
It asserts that the script accepts no harness, model, or provider input, never calls `quota-axi`, exits alike for every probe result because it renders no verdict, invokes only the two fixed non-destructive argv forms with stdin closed, holds a real bound even when the configured bound is zero or malformed, and never echoes raw vendor output.
`tests/fm-spawn-dispatch-profile.test.sh` owns spawn's deterministic profile, seat, and harness refusals, asserting the literal launch command each seat produces.
`tests/fm-codex-seats.test.sh` owns the `config/codex-seats` contract, the per-seat quota read against a fake producer, and the credential-free mirror.
`tests/fm-control-relaunch.test.sh` owns seat continuity across a replacement agent.
`tests/fm-bootstrap.test.sh` owns the quota-axi version-floor diagnostic.
`tests/fm-quota-array-dispatch-live-e2e.test.sh` drives the public Pi skill-loading interface against one fake `quota-axi --json` snapshot per case.
It covers the Claude 1 percent versus Codex 55 percent reserve regression, explicit accounting for unmeasurable runway, and the strongest-reasoning constraint.
