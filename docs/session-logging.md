# Session logging, audit, and availability

### Availability

`desired_capacity` defaults to 1. Raising it does **not** keep an in flight
tunnel alive: SSM sessions bind to an instance ID and cannot fail over. What a
second instance buys is time to reconnect, immediate rather than waiting out an
Auto Scaling Group replacement of roughly three minutes.

### Session logging and audit

CloudTrail is the audit source, not Session Manager transcript logging.
Transcripts capture terminal output, and port forwarding sessions have no
terminal. CloudTrail `StartSession` events carry the caller identity, the target
instance, the document name, and the port forwarding parameters, which is who
connected, when, and to which private host and port.

The module turns that into two log groups, both at `log_retention_days` (7 by
default), and one dashboard.

| Log group | Holds | Created when |
|---|---|---|
| `/aws/bastion/<name>/connections` | One flat record per `StartSession`, `ResumeSession`, and `TerminateSession`: principal, source IP, target instance, tunnelled host and port, session ID | `logging_enabled` (default true) |
| `/aws/ssm/session/<name>` | Full terminal transcripts of interactive shells | `session_preferences_managed` (default false) |

The connection audit covers every session type, including the port forwards
`client/tunnel.sh` opens. Transcript logging covers interactive shells only.

### Prerequisite: a CloudTrail trail in the region

Session Manager publishes no native EventBridge event, so the audit rule matches
CloudTrail-sourced API calls, and those reach EventBridge only while a trail is
logging management events. Without a trail the log group stays empty and the
dashboard shows nothing.

```bash
aws cloudtrail describe-trails --query 'trailList[].{Name:Name,Multi:IsMultiRegionTrail}' --output table
```

Most accounts already have an organization trail. The module does not create
one, because a trail is account level state that outlives any single bastion.

### Turning on shell transcripts

`session_preferences_managed = true` creates `SSM-SessionManagerRunShell`. That
document is an **account and region singleton**: it governs shell logging for
every SSM session in the region, not only this bastion's, and two deployments in
one account collide on it. Leave it false in shared accounts.

If the document already exists, import it first or the apply fails:

```bash
terraform import 'module.bastion.aws_ssm_document.session_preferences[0]' SSM-SessionManagerRunShell
```

Running with `create_iam_role = false` means the module cannot grant the
instance the CloudWatch Logs writes transcripts need, since it does not own the
role. Attach `terraform output -raw session_log_policy_json` to your role
yourself.

### Dashboard

`terraform output -raw dashboard_url` opens it. Seven widgets: recent sessions,
sessions per principal, event counts, instances in service, CPU, network, and
shell transcripts. Log widgets follow the dashboard time picker, which defaults
to the last 7 days.

Session duration is not a widget, because it needs start and end paired by
session ID. Run this in Logs Insights against the audit group instead:

```
fields @timestamp, event, principal, coalesce(sessionId, endedSession) as sid, targetHost, targetPort
| stats earliest(principal) as who,
        earliest(targetHost) as host,
        earliest(targetPort) as port,
        min(@timestamp) as started,
        max(@timestamp) as ended,
        (max(@timestamp) - min(@timestamp)) / 1000 as duration_seconds
  by sid
| sort started desc
```

A row with `duration_seconds` near zero is a session still open, or one whose
`TerminateSession` fell outside the query window.

### Scope of the audit rule

Session targets are instance IDs the Auto Scaling group assigns at launch, so
they cannot be matched in a static EventBridge pattern. The rule therefore
records SSM sessions to **every instance in the region**, not only this
bastion's. That is a wider net rather than a narrower one; the `instance` field
identifies which host each session went to.
