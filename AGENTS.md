# AGENTS.md

Project guidance for AI coding agents working in this repository. See also `CLAUDE.md` for the domain documentation.

## Superpowers bootstrap

You have Superpowers installed. Use it.

1. At the start of any session or new task, load the `using-superpowers` skill with the Skill tool and follow it.
2. Before ANY response or action — including clarifying questions, exploring the codebase, or checking files — check whether a Superpowers skill applies to the task. If there is any chance a skill applies, invoke it first.
3. Process skills come before implementation skills: brainstorm before writing code, systematically debug before fixing bugs, write a plan before large changes, and follow TDD (RED-GREEN-REFACTOR) during implementation.
4. If in doubt whether a skill fits, load it anyway; skip it only if it turns out to be wrong for the situation.

Available Superpowers skills (installed globally in `~/.kilocode/skills/`):
brainstorming, writing-plans, executing-plans, subagent-driven-development, dispatching-parallel-agents, using-git-worktrees, finishing-a-development-branch, test-driven-development, systematic-debugging, verification-before-completion, requesting-code-review, receiving-code-review, writing-skills, using-superpowers.
