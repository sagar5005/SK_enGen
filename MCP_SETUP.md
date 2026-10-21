# Connecting to SQL Server via MCP

This repo uses the `mssql-mcp-server` npm package (read-only schema and stored procedure tools) configured in `.mcp.json`.

1. Set `MSSQL_CONNECTION_STRING` in your environment (see `.env.example`). Do not commit credentials.
2. Start Claude Code in this folder and approve the `mssql` project server when prompted.
3. Run `/mcp` to confirm it is connected, then ask Claude to run `test_connection`.

The server must be able to reach your SQL Server host. A private or on-prem server is not reachable from a Claude cloud session, so run Claude Code on a machine on your network or VPN. For a cloud session, the host must be public and allowed by the environment's network policy.

Tools such as `describe_stored_procedure` and `get_stored_procedure_definition` work against `AutoMig.usp_populate_jab_migrationqueue`. `execute_query` is off unless `MSSQL_ENABLE_EXECUTE_QUERY=true`.
