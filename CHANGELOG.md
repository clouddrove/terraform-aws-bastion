# Changelog

All notable changes to this project are documented here. This file is
maintained by the `changelog` workflow, which runs on tag push and generates
entries from conventional commits.

## 1.0.0

First tagged release.

- SSM-only EC2 bastion: no SSH key, no public IP, no inbound security group rules
- Session logging: connection audit and optional shell transcripts in CloudWatch Logs, 7 day retention, with a dashboard
- Client: SSM port forwarding plus a local HAProxy SNI router, reaching EKS, internal ALBs, Aurora, RDS Proxy, RDS PostgreSQL and MySQL, ElastiCache Redis and memcached, DocumentDB, OpenSearch, MSK, and arbitrary hosts through `custom[]`
- Five examples: `basic`, `complete`, `with-targets`, `session-transcripts`, `minimal`
