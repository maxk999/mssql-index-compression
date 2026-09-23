# mssql-index-compression

Per-index data compression for SQL Server, as a companion to
[Ola Hallengren's Maintenance Solution](https://ola.hallengren.com/).
Background and discussion: [olahallengren/sql-server-maintenance-solution#1176](https://github.com/olahallengren/sql-server-maintenance-solution/issues/1176).

| File | What it does |
|---|---|
| `IndexCompression.sql` | Stored procedure `dbo.IndexCompression`. Sets `DATA_COMPRESSION` on partitions that are still uncompressed. `@DataCompression = 'AUTO'` decides PAGE, ROW or NONE for each index from the estimated savings and the update share; `'PAGE'` / `'ROW'` force a value. Heaps are included. Commands go through `dbo.CommandExecute` and are logged to `dbo.CommandLog`. |
| `compression_review.sql` | Read-only report for partitions that are already compressed: PAGE → ROW and ROW → PAGE candidates. It prints the `sp_estimate_data_compression_savings` call for each flagged partition and changes nothing. |

## Usage

Install `IndexCompression.sql` into the database that holds `CommandExecute` (usually `master`).
In the job, run it **before** `IndexOptimize`: the compression rebuild also defragments, so IndexOptimize skips those indexes.

```sql
EXECUTE dbo.IndexCompression
    @Databases = 'USER_DATABASES',
    @DataCompression = 'AUTO',
    @Online = 'Y',
    @WaitAtLowPriorityMinutes = 1,
    @TimeLimit = 3600,
    @LogToTable = 'Y';
```

Preview without changes: `@Execute = 'N'`. All parameters are documented in the header of the procedure.

Run `compression_review.sql` occasionally, for example after month-end and at least two weeks after a compression rollout.

## License

[MIT](LICENSE)
