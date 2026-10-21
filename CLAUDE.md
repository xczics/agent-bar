# agent-bar — notes for Claude

C++17 + CMake. `core/` is platform-independent and unit-tested; `hook/` is the
Claude Code hook; `platform/mac/main.mm` is the Cocoa floating window. The spec
is `docs/design.md`.

## Build & test

```sh
cmake -S . -B build && cmake --build build -j
ctest --test-dir build --output-on-failure
scripts/acceptance.sh && scripts/bar-smoke.sh
```

Test scripts use a throwaway `AGENT_STATUS_DIR`; never test against the real
`~/.claude`. `agent-bar --snapshot out.png [compact|expanded]` renders the UI
without screen-recording permission — use it to check visual changes.

## Documentation rules (from the user)

- `Handoff.md` holds only **in-progress** and **planned** work. When something
  is done, move it to `changelog/unreleased.md`; at release time that file is
  renamed to `changelog/vX.Y.Z.md` (one file per version; it doubles as the
  GitHub release notes).
- `docs/tutorial.md` must match the current behaviour. Update it in the same
  change as any user-visible behaviour, flag or install step.
- `Inbox.md` is the user's drop box. Read it at the start of a session and
  whenever asked; for each item, record it in Handoff.md / docs (it does not
  need to be implemented yet), then delete that item. Keep the file empty
  otherwise.
- User-facing docs are in Chinese.

## Release

Bump `project(agent-bar VERSION …)` in CMakeLists.txt, add `changelog/vX.Y.Z.md`,
push tag `vX.Y.Z`; `.github/workflows/release.yml` builds and publishes.
