# Pi Calm mode

Calm is a Pi-only conversation presentation toggle.
It is off by default, and the last `/calm` choice persists for the effective Firstmate home across Pi session starts and resumes.

While Calm is active and an agent run is under way, Calm hides Pi's built-in `Working...` row and shows a small two-row animated boat in its place, and no separate Calm status row is added.
The water fills the usable width in standard ANSI blue and the complete boat is standard ANSI yellow.
The boat is deliberately calm: it moves one column every 880ms, while the water ripples on its own faster cadence so the surface stays alive between boat steps.
Its mainsail is directional, showing `<|` while travelling right and `|>` while travelling left, and it flips on the exact frame the boat turns at either edge.
Every resize reflows the sprite without wrapping, and it disappears when the run settles, aborts, or fails.
Within one Pi session and Calm extension lifetime, the next working period resumes the boat from its last rendered column and travel direction rather than restarting at the left edge.
Hidden elapsed time does not advance the animation, and a resize while hidden clamps the frozen boat to the new width without changing its valid travel direction.
A fresh Pi session or new Calm extension lifetime starts at the normal initial position.
Very narrow terminals fall back to a smaller deterministic sprite.
While Calm is off, Pi's stock working row is left exactly as Pi renders it.
Calm hides collapsed thinking labels, the shells for Pi's seven built-in tools, the `fm_watch_arm_pi` tool shell, and canonically classified Firstmate operational user rows.
The operational inputs remain ordinary user-role messages, while Pi's transcript layout renders their complete rows at zero height.
The session-start nudge remains on its existing non-displayed custom-message path.

Calm changes presentation only.
Tool execution, input delivery, ordering, model context, session storage, diagnostics, and `/export` and `/share` operation remain unchanged.
Every hidden Firstmate input remains available to the model and in serialized session data and exported artifacts.
Legacy operational custom messages remain in session data and Pi's sidebar tree, although the main HTML transcript may omit them.
Toggling Calm off restores ordinary rendering, and `Ctrl+O` expansion state is preserved.

Pi's supported presentation API does not expose a global transcript filter.
Expanded reasoning and its reserved spacing, built-in tool images, user-bash rows, skill and summary rows, generic status notices, and arbitrary custom-tool or extension rows remain visible.
These are supported-API boundaries rather than hidden-content failures.

## Pi compatibility

Calm has no numeric Pi version minimum or maximum and never refuses Pi solely because its version is newer than a previously verified version.
The collapsed-thinking and operational-user-row presentation adapters probe the exact Pi API seam they patch when Calm loads.
If Pi removes one of those seams, Calm logs a diagnostic naming the unavailable adapter and skips only that adapter; `/calm`, the other adapter, and unrelated Pi extensions remain available.

Calm's built-in tool presentation (`bash`, `read`, `edit`, `write`, `grep`, `find`, `ls`) shares Pi's single, unmerged built-in-tool-override slot per name with any other extension that also overrides one of those tools, so Calm only claims a name a different extension has not already claimed.
It registers nothing at all while Calm is off, so a user who has never turned Calm on never contests a name.
The first time Calm turns on in a session that started off, it claims every built-in name no other extension already owns and prints a prominent warning naming any it could not, leaving that other extension's own tool fully intact and working; every session afterward starts with Calm already on and re-claims all seven at once, matching a captain's own long-running preference.
One bound comes with that: the very first time a session that started Calm-off turns Calm on, tool-call rows already on screen from before that toggle do not retroactively collapse, because Pi never lets an extension re-point an already-rendered row at a definition registered later; new rows from that point on, and every row in every later session, are unaffected.
One case still cannot be checked ahead of time: a session that starts, or reloads, with Calm already on, where the tool registry snapshot Pi needs for that render is taken before Calm gets any chance to check who owns a name.
For that case a session-start diagnostic names the tool and the extension that won it.
`.pi/extensions/fm-calm.ts`'s file header carries the full explanation and the Pi-source evidence behind it.

[`calm-mode-feasibility.md`](calm-mode-feasibility.md) owns the version-scoped renderer taxonomy and empirical evidence.
[`configuration.md`](configuration.md#pi-calm-preference-configcalm) owns the persisted preference file and resolution rules.
`.pi/extensions/lib/fm-calm-visibility.ts` owns the visibility policy, `.pi/extensions/lib/fm-calm-operational-user-layout.ts` owns the zero-height operational-user row adapter, and `.pi/extensions/lib/fm-calm-working-ship.ts` owns the animated working presentation.

Regression entry points:

```sh
tests/fm-calm-pi-extension.test.sh
tests/fm-pi-primary-types.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
```
