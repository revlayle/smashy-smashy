# Coding session prompts

Copy-paste prompts for starting Claude Code sessions on this project. Open the session in `C:\Games\c64-platformer-demo`. `CLAUDE.md` loads automatically, so these prompts stay short.

## Start the next phase

Use this for every new phase, including phase 1.

```
Continue the C64 platformer build.

1. Read docs/phases.md and follow "How to work a phase". Work on the first phase that is not done.
2. Read docs/spec.md in full before writing code. Use the prog8-coder skill for Prog8, and asm6502-coder for any inline assembly.
3. Look up register details in docs/c64/ and Prog8 library signatures in tools/prog8-src/ instead of relying on memory.
4. Verify every "Done when" item yourself: build with build.cmd, run in VICE, and check screenshots. Use scripted input for anything that needs the joystick.
5. When the phase passes, update its status and notes in docs/phases.md. Then stop and give me:
   - what was built
   - the result of each "Done when" check
   - anything that differs from the spec
   - what I should test by hand in VICE (feel, speed, controls)

Don't start the next phase. Ask me before changing any gameplay rule.
```

## Fix things after playtesting

Use this after you've played a phase's build and want changes.

```
I played the phase <N> build. Feedback:

- <what felt wrong or broke, e.g. "jump feels floaty", "player sticks to walls when jumping into them">
- <...>

Fix these within phase <N>. If a fix changes a value or rule in docs/spec.md, update the spec and say which. Verify again, rebuild, and launch it in VICE for me to test. Then update the notes for phase <N> in docs/phases.md.
```

## Resume an interrupted phase

Use this if a session ended mid-phase.

```
A previous session was working on the phase marked "in progress" in docs/phases.md and stopped before finishing.

Check what already exists in src/, assets/ and tools/ against that phase's "Build" list. Then build and run what's there to see the current state. Finish the remaining work, verify every "Done when" item, and report as described in "How to work a phase".
```

## Run the current build

```
Build the project and launch it in VICE so I can play it.
```

## Tips

- One phase per session works best: each session starts clean, and the docs carry all state between sessions.
- If a session drifts or gets confused, end it and start a new one with the resume prompt. Nothing is lost, because progress lives in the files.
- Tuning feel (speeds, jump height) is easiest as a quick back-and-forth inside one session: "jump 10% faster, rebuild, launch".
