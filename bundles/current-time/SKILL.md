---
name: current-time
description: Get the user's current local time
---
This bundle provides the **get_current_time** tool, which retrieves the user's current local time in a human-readable `HH:MM:SS` format.

### When to Use It
Use this bundle when you need to query the current time of the system using this tool. It can be particularly useful in workflows where you need to ensure time-based actions are synchronized.

### How to Use It
To use the **get_current_time** tool, call it without any arguments. The script will return the current time in the format:

```json
{"time": "14:30:00", "message": "Current time retrieved successfully."}
```

### Notes
- The result includes both the time and a confirmation message.
- The tool does not require any parameters.
- Ensure your system clock is accurate if precision is important.
