# Logging Options

NkSIP uses [logger](https://www.erlang.org/doc/apps/kernel/logger.html) for logging, supporting multiple log levels, log rotation, etc. The following `logger` levels are used:

Level|Typical use
---|---
`debug`|Maximum level of information. Do not use it in production
`info`|Detailed information. Not recommended in production
`notice`|Important information. Recommended in production
`warning`|Actions you should take into account
`error`|Important internal errors
`critical`|Not used currently
`alert`|Not used currently
`emergency`|Not used currently

You can configure logger using its erlang environment variables, or using an erlang start up configuration file (usually called `app.config`). See the `samples` directory for an example of use.

To get SIP message tracing, activate the [nksip_trace](../plugins/trace.md) plugin.
