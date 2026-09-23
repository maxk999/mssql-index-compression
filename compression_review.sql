/*
====================================================================================================
  compression_review.sql - which already compressed partitions should have their compression
  decision reviewed.

  dbo.IndexCompression (and IndexOptimize @DataCompression) only decide for partitions that are
  still uncompressed. Once a partition is PAGE or ROW, nobody looks at it again - but the
  workload can change after the initial decision. This report flags:

    PAGE -> ROW   page compression attempts mostly fail: CPU is spent on every page fill for
                  nothing (page_compression_success_count / page_compression_attempt_count low);
    PAGE -> ROW   the partition became update-heavy - by share AND by absolute rate, so a
                  nearly idle table with a high share is not flagged;
    ROW  -> PAGE  the partition is no longer update-heavy - PAGE may now pay off (estimate first).

  Read-only: reads metadata and DMVs only. It does NOT run sp_estimate_data_compression_savings
  (that reads data into tempdb); the Estimate column contains the call to run by hand.

  CAVEATS:
    - sys.dm_db_index_operational_stats is reset on restart, when the metadata leaves the cache,
      and when the index is rebuilt. Rates are computed from the server start, so they are a
      LOWER bound. Run the report at least 2 weeks after a compression rollout.
    - This is a review list, not an automatic action: a flip-flopping decision means a rebuild
      of a large table every time. A person decides.

  Run: sqlcmd -S <server> -E -C -i compression_review.sql
====================================================================================================
*/

SET NOCOUNT ON;

DECLARE @Databases        nvarchar(max) = NULL;  -- 'SalesDB,Archive'; NULL = all online user databases
DECLARE @MinPages         int           = 131072; -- 1 GB: a rebuild of a smaller partition does not pay off
DECLARE @MaxUpdatePct     int           = 20;    -- same threshold as IndexCompression
DECLARE @MinUpdatesPerSec decimal(9,3)  = 1;     -- below this rate the update share is ignored
DECLARE @MinAttempts      bigint        = 1000;  -- too few attempts say nothing
DECLARE @MinSuccessPct    int           = 20;    -- PAGE success rate below this = CPU wasted

DECLARE @Uptime bigint = (SELECT DATEDIFF(SECOND, sqlserver_start_time, SYSDATETIME()) FROM sys.dm_os_sys_info);

CREATE TABLE #Review (
  DatabaseName   sysname      NOT NULL,
  SchemaName     sysname      NOT NULL,
  ObjectName     sysname      NOT NULL,
  IndexID        int          NOT NULL,
  IndexName      sysname      NULL,
  PartitionNo    int          NOT NULL,
  Compression    nvarchar(60) NOT NULL,
  PageCount      bigint       NOT NULL,
  LeafUpdates    bigint       NULL,
  LeafOps        bigint       NULL,
  Attempts       bigint       NULL,
  Successes      bigint       NULL
);

DECLARE @Db sysname, @Proc nvarchar(300), @Sql nvarchar(max);

DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
  SELECT d.name
  FROM sys.databases d
  WHERE d.database_id > 4
    AND d.state_desc = 'ONLINE'
    AND DATABASEPROPERTYEX(d.name, 'Updateability') = 'READ_WRITE'
    AND (@Databases IS NULL
         OR d.name IN (SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Databases, ',')));

OPEN dbs;
FETCH NEXT FROM dbs INTO @Db;

WHILE @@FETCH_STATUS = 0
BEGIN
  SET @Sql = N'
    INSERT #Review (DatabaseName, SchemaName, ObjectName, IndexID, IndexName, PartitionNo,
                    Compression, PageCount, LeafUpdates, LeafOps, Attempts, Successes)
    SELECT DB_NAME(), s.name, t.name, i.index_id, i.name, p.partition_number,
           p.data_compression_desc, ps.used_page_count,
           os.leaf_update_count,
           os.leaf_insert_count + os.leaf_update_count + os.leaf_delete_count
             + os.leaf_page_merge_count + os.range_scan_count + os.singleton_lookup_count,
           os.page_compression_attempt_count,
           os.page_compression_success_count
    FROM sys.tables t
    INNER JOIN sys.schemas s    ON s.[schema_id] = t.[schema_id]
    INNER JOIN sys.indexes i    ON i.[object_id] = t.[object_id]
    INNER JOIN sys.partitions p ON p.[object_id] = i.[object_id] AND p.index_id = i.index_id
    INNER JOIN sys.dm_db_partition_stats ps ON ps.partition_id = p.partition_id
    LEFT JOIN sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) os
           ON os.[object_id] = p.[object_id]
          AND os.index_id = p.index_id
          AND os.partition_number = p.partition_number
    WHERE t.is_ms_shipped = 0
      AND i.[type] IN (0, 1, 2)
      AND p.data_compression IN (1, 2)          -- ROW, PAGE
      AND ps.used_page_count >= @MinPages;';

  BEGIN TRY
    SET @Proc = QUOTENAME(@Db) + N'.sys.sp_executesql';
    EXECUTE @Proc @Sql, N'@MinPages int', @MinPages = @MinPages;
  END TRY
  BEGIN CATCH
    PRINT 'Database ' + @Db + ': ' + ERROR_MESSAGE();
  END CATCH

  FETCH NEXT FROM dbs INTO @Db;
END

CLOSE dbs;
DEALLOCATE dbs;

WITH m AS (
  SELECT *,
         CAST(100.0 * LeafUpdates / NULLIF(LeafOps, 0) AS decimal(5,2))       AS UpdatePct,
         CAST(1.0 * LeafUpdates / NULLIF(@Uptime, 0) AS decimal(12,3))        AS UpdatesPerSec,
         CAST(100.0 * Successes / NULLIF(Attempts, 0) AS decimal(5,2))        AS SuccessPct
  FROM #Review
), r AS (
  SELECT *,
         CASE
           WHEN Compression = 'PAGE' AND Attempts >= @MinAttempts AND SuccessPct < @MinSuccessPct
                THEN 'PAGE -> ROW'
           WHEN Compression = 'PAGE' AND UpdatePct > @MaxUpdatePct AND UpdatesPerSec >= @MinUpdatesPerSec
                THEN 'PAGE -> ROW'
           WHEN Compression = 'ROW' AND (ISNULL(UpdatePct, 0) <= @MaxUpdatePct OR ISNULL(UpdatesPerSec, 0) < @MinUpdatesPerSec)
                THEN 'ROW -> PAGE?'
         END AS Suggestion,
         CASE
           WHEN Compression = 'PAGE' AND Attempts >= @MinAttempts AND SuccessPct < @MinSuccessPct
                THEN 'only ' + CAST(SuccessPct AS varchar(20)) + '% of ' + CAST(Attempts AS varchar(20))
                   + ' page compression attempts succeeded - CPU spent for nothing'
           WHEN Compression = 'PAGE' AND UpdatePct > @MaxUpdatePct AND UpdatesPerSec >= @MinUpdatesPerSec
                THEN 'update-heavy: ' + CAST(UpdatePct AS varchar(20)) + '% of leaf ops, '
                   + CAST(UpdatesPerSec AS varchar(20)) + ' updates/s'
           WHEN Compression = 'ROW'
                THEN 'no longer update-heavy: ' + ISNULL(CAST(UpdatePct AS varchar(20)), '0') + '%, '
                   + ISNULL(CAST(UpdatesPerSec AS varchar(20)), '0') + ' updates/s - estimate PAGE first'
         END AS Reason
  FROM m
)
SELECT Suggestion,
       DatabaseName,
       SchemaName + '.' + ObjectName                      AS [Table],
       ISNULL(IndexName, '(heap)')                        AS [Index],
       PartitionNo,
       CAST(PageCount * 8.0 / 1024 / 1024 AS decimal(9,2)) AS GB,
       UpdatePct,
       UpdatesPerSec,
       Attempts,
       SuccessPct,
       Reason,
       'EXEC ' + QUOTENAME(DatabaseName) + '.sys.sp_estimate_data_compression_savings '''
         + SchemaName + ''', ''' + ObjectName + ''', ' + CAST(IndexID AS varchar(10)) + ', '
         + CAST(PartitionNo AS varchar(10)) + ', '''
         + CASE WHEN Compression = 'PAGE' THEN 'ROW' ELSE 'PAGE' END + ''';' AS Estimate
FROM r
WHERE Suggestion IS NOT NULL
ORDER BY Suggestion, PageCount DESC;

SELECT Compression,
       COUNT(*)                                           AS Partitions,
       CAST(SUM(PageCount) * 8.0 / 1024 / 1024 AS decimal(9,2)) AS GB,
       CAST(@Uptime / 86400.0 AS decimal(9,1))            AS StatsWindowDays
FROM #Review
GROUP BY Compression;

DROP TABLE #Review;
