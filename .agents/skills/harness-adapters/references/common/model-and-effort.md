# Model and effort

Load this with the selected tool reference before choosing, validating, or changing either axis.
Add `references/common/dispatch.md` for configured profile precedence.

## Axes and precedence

`../../../bin/fm-spawn.sh` accepts concrete `--harness`, `--model`, `--effort`, and `--seat` values selected at intake; scripts never parse natural-language dispatch rules.
The tool reference records verified flags, accepted values, omission behavior, and discovery.

Effort precedence is a per-task captain instruction, then applicable dispatch profile or secondmate pin, then the fallback below.
Never replace either higher-precedence value.
Use the fallback only when neither specifies effort.

Use `low` for well-understood work with an explicit bounded path and `xhigh` for ambiguous investigation or design.
Choose intermediate levels as complexity, uncertainty, blast radius, or open-ended reasoning rises.
If an adapter lacks `xhigh`, cap at its highest supported non-`max` level rather than silently omitting the intent.
Never select `max` through this fallback; only an explicit per-task or standing captain preference permits it.

The explicit native `ultra` value follows the model-scoped refusal contract in `../../../bin/fm-harness.sh validate-native-effort`; it is never silently omitted or mapped to a Pi level.
For other values, if requested effort is outside the adapter's accepted set, the spawn records `effort=` in task metadata but emits no effort flag.
This preserves launch success instead of passing a known-bad value.
A harness with no verified interactive effort flag follows the same record-and-omit contract.

## Codex seats

A Codex team workspace can hold more than one subscription seat, and each seat has its own usage windows.
`config/codex-seats` names them, and a seat is a fourth launch profile axis alongside harness, model, and effort: `../../../bin/fm-spawn.sh --seat <name>`.
It reaches exactly two runtimes, because those are the ones that spend a Codex seat: `harness=codex`, where it sets `CODEX_HOME`, and a `pi`/`pi-signed` launch on an `openai-codex/*` model, where it sets `PI_CODING_AGENT_DIR`.
Every other harness or model is a refusal, not a silently dropped flag.
The operator-facing `config/pi-account` conflict rule is owned by `../../../docs/configuration.md`: spawn and relaunch refuse before endpoint creation when a Pi `openai-codex/*` launch names both a worker-account pin and a Codex seat, because both select `PI_CODING_AGENT_DIR`.
`../../../docs/configuration.md` "Codex seats" owns the file format, the one-time per-store sign-in, and the mirror helper; `../../../bin/fm-codex-seat-lib.sh` owns the executable contract.

Treat each configured seat as its own quota scope, because it is one: `quota-axi` reports a seat's windows only when pointed at that seat's store, and one seat's exhausted window says nothing about another's.
Read them with `../../../bin/fm-codex-seat.sh quota --json`, which runs the same producer once per seat and labels each report with its seat and store.
When a Codex candidate's seat is tight, prefer another configured seat over waiting on a reset, and resolve the choice through `quota-array-dispatch` exactly as any other profile array.
A dispatch profile carries the axis as an optional `"seat"` field, so two candidates differing only by seat are the ordinary way to express "whichever seat has headroom".

A task records the seat it launched on as `seat=` in its metadata, and every replacement agent keeps spending that same seat unless `../../../bin/fm-control.sh relaunch --seat <name>` names another one.
Never copy a credential between two stores: Codex OAuth refresh tokens rotate, so a second reader of one store's `auth.json` can log the first consumer out.
Each store is signed in on its own.

## Harness and provider identity

Harness identity is independent of model provider.
`harness=pi` with `model=xai/grok-*` is Pi using xAI, not standalone Grok Build, and does not require Grok CLI login.
`harness=cursor` with `model=cursor-grok-4.5-*` is Cursor routing a Grok model, not `harness=grok`.

No script resolves credential provenance for you.
Establish it from the tool's discovery surface and `quota-axi auth --json` per-provider sources, and show the reasoning rather than inferring it from a name.

## Discovery

Treat model and provider knowledge as current discovery, not a permanent namespace or mapping.
Use the selected tool reference's authoritative surface in the current authenticated environment because availability changes by version, account, and configuration.

For an unfamiliar namespace, establish support and provider identity from that harness's CLI help, model listing, or current documentation.
An account-reaching listing that omits a model is concrete unsupported evidence; block the candidate and quote it.
An unreachable surface establishes nothing; report uncertainty instead of a verdict.

For a matched profile array, return to `quota-array-dispatch` only after establishing every candidate's harness support, provider relationship, and uncertainty.
