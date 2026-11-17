---
description: "Stop the harness runner after the current session"
allowed-tools: ["Bash(touch .harness/STOP:*)", "Bash(.harness/status.sh:*)"]
---

```!
touch .harness/STOP && echo "STOP flag set: the loop exits after the current session finishes (both loop modes check the flag before each new session; a running agent is not interrupted)."
```

Tell the user the loop will stop after the current session, and that starting `/wreck-it-ralph:run` or `.harness/run.sh` again resumes work and clears the flag (all state is on disk). To stop the current agent immediately, interrupt the session (Esc) or kill the headless runner.
