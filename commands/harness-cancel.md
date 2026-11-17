---
description: "Stop the harness runner after the current session"
allowed-tools: ["Bash(touch .harness/STOP:*)", "Bash(.harness/status.sh:*)"]
---

```!
touch .harness/STOP && echo "STOP flag set: the loop exits after the current session finishes (both loop modes check the flag before each new session)."
```

Tell the user the loop will stop after the current session, and that removing `.harness/STOP` or starting `.harness/run.sh` again resumes work (all state is on disk).
