# CLAUDE.md

Read the project's CLAUDE.md file first. Follow all conventions and standards defined there.

# ISSUES

Issues JSON is provided at start of context. Parse it to get open issues with their bodies and comments.

You've also been passed the last 10 RALPH commits (SHA, date, full message). Review these to understand what work has been done.

# TASK SELECTION

Pick the next task. Prioritize tasks in this order:

1. Critical bugfixes
2. Tracer bullets for new features

Tracer bullets come from the Pragmatic Programmer. When building systems, write code that gets you feedback as quickly as possible. Tracer bullets are small slices of functionality that go through all layers of the system, allowing you to test and validate your approach early. This helps identify potential issues and ensures that the overall architecture is sound before investing significant time in development.

TL;DR — build a tiny, end-to-end slice of the feature first, then expand it out.

3. Polish and quick wins
4. Refactors

If a task has "Depends on #X" in its body, check whether #X is closed. If not, skip that task and pick a different one.

If all tasks are complete, output <promise>COMPLETE</promise>.

# EXPLORATION

Explore the repo and fill your context window with relevant information that will allow you to complete the task.

# EXECUTION

Complete the task.

# QUALITY GATE

Before committing, run the project's quality checks:

1. **Typecheck** — run the typecheck command (e.g., `tsc --noEmit`, `tsgo`, `react-router typegen && tsgo`)
2. **Tests** — run the test suite (e.g., `npm test`, `pnpm test`, `vitest run`)
3. **Build** — run the build command (e.g., `npm run build`, `pnpm build`)

If any of these fail, fix the issues before committing. Do not commit code that fails the quality gate.

If the project doesn't have one of these commands, skip that check.

# COMMIT

Make a git commit. The commit message must:

1. Start with `RALPH:` prefix
2. Include task completed + issue reference (e.g., "fixes #12")
3. Key decisions made
4. Files changed
5. Blockers or notes for next iteration

Keep it concise.

# THE ISSUE

If the task is complete, close the original GitHub issue with a comment summarizing what was done.

If the task is not complete, leave a comment on the GitHub issue with what was done and what remains.

# FINAL RULES

ONLY WORK ON A SINGLE TASK.
