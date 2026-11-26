# AGENTS.md

Instructions for AI agents and contributors working in this repository.

- Read `docs/PLAN.md` (overall plan) and `docs/AGENT_PROMPT.md` (implementation instructions for the recommended Track A) before changing anything.
- All documentation, comments, commit messages and PR descriptions are in **English**.
- Every change goes through a **pull request**. No direct pushes to `main`, no force-push, no merging without the owner's explicit request and green CI.
- Compiler and driver code is written in **Zig** (pinned 0.17.1) with **LLVM 22**. Rust code is allowed only in the thin `shim/` crate that implements rustc's `CodegenBackend`.
- No new third-party dependencies without the owner's approval.
- This is an unofficial project, not affiliated with the official Rust project or Rust Foundation. Keep that notice in `README.md`.
