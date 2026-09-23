/*
====================================================================================================
  dbo.CompressionReview - which already compressed partitions should have their compression
  decision reviewed.

  dbo.IndexCompression (and IndexOptimize @DataCompression) only decide for partitions that are
  still uncompressed. Once a partition is PAGE or ROW, nobody looks at it again - but the
  workload can change after the initial decision. This procedure flags:

    PAGE -> ROW   page compression attempts mostly fail: CPU is spent on every page fill for
                  nothing (page_compression_success_count / page_compression_attempt_count low);
    PAGE -> ROW   the partition became update-heavy - by share AND by absolute rate, so a
                  nearly idle table with a high share is not flagged;
    ROW  -> PAGE? the partition is no longer update-heavy - PAGE may now pay off (estimate first).

  Read-only for user databases: reads metadata and DMVs only. It does NOT run
  sp_estimate_data_compression_savings (that reads data into tempdb); the Estimate column
  contains the call to run by hand. Nothing is ever rebuilt.

  HISTORY AND CONFIRMATION (@LogToTable = 'Y'):
    Every run is recorded in dbo.CompressionReviewRun, flagged partitions in dbo.CompressionReviewLog.
    A suggestion is Confirmed only when the same partition got the same suggestion in each of the
    last @ConfirmRuns runs. Workloads are seasonal (month-end close turns quiet tables hot), and a
    decision that flips back and forth means a rebuild of a large table every time - act on
    Confirmed rows only. Schedule it monthly, after month-end, so every run sees a full cycle.

  STATS WINDOW:
    sys.dm_db_index_operational_stats is reset on restart, when the metadata leaves the cache, and
    when the index is rebuilt. The window of a partition starts at the later of the server start
    and its last REBUILD in dbo.CommandLog (IndexOptimize, IndexCompression). Partitions with a
    window shorter than @MinStatsDays are skipped: their counters say too little. Cache eviction is
    not visible anywhere, so rates remain a LOWER bound.

  INSTALL: into the same database as CommandExecute and CommandLog (usually master).

  EXAMPLES:

    -- monthly job step, after month-end
    EXECUTE dbo.CompressionReview @Databases = 'USER_DATABASES', @LogToTable = 'Y';

    -- ad hoc look, leaves no history
    EXECUTE dbo.CompressionReview @Databases = 'SalesDB';

    -- what was confirmed by the last run
    SELECT r.* FROM dbo.CompressionReviewLog r
    WHERE r.RunID = (SELECT MAX(RunID) FROM dbo.CompressionReviewRun) AND r.Confirmed = 1;

  PARAMETERS:
    @Databases        USER_DATABASES (default) or a comma-separated list of names.
    @MinPages         Minimum partition size. Default 131072 pages = 1 GB: a rebuild of a smaller
                      partition does not pay off.
    @MaxUpdatePct     Update share threshold, the same as in IndexCompression. Default 20.
    @MinUpdatesPerSec Below this rate the update share is ignored. Default 1.
    @MinAttempts      Fewer page compression attempts say nothing. Default 1000.
    @MinSuccessPct    PAGE success rate below this = CPU wasted. Default 20.
    @MinStatsDays     Minimum stats window of a partition. Default 14.
    @ConfirmRuns      How many consecutive runs must agree. Default 2.
    @LogToTable       Y/N, default N. Y writes the history and computes Confirmed.

  Source: independent work, compatible with the Ola Hallengren Maintenance Solution license
          (https://ola.hallengren.com/license.html) as a separate object.
====================================================================================================
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[CompressionReview]') AND type IN (N'P', N'PC'))
BEGIN
  EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [dbo].[CompressionReview] AS'
END
GO

ALTER PROCEDURE [dbo].[CompressionReview]

@Databases        nvarchar(max) = 'USER_DATABASES',
@MinPages         int           = 131072,
@MaxUpdatePct     int           = 20,
@MinUpdatesPerSec decimal(9,3)  = 1,
@MinAttempts      bigint        = 1000,
@MinSuccessPct    int           = 20,
@MinStatsDays     int           = 14,
@ConfirmRuns      int           = 2,
@LogToTable       nvarchar(max) = 'N'

AS

BEGIN
  SET NOCOUNT ON;

  IF @LogToTable NOT IN ('Y', 'N') OR @ConfirmRuns < 1 OR @MinStatsDays < 0
  BEGIN
    RAISERROR('@LogToTable accepts Y or N, @ConfirmRuns must be at least 1, @MinStatsDays at least 0.', 16, 1) WITH NOWAIT;
    RETURN 1;
  END

  DECLARE @Now         datetime2(0) = SYSDATETIME();
  DECLARE @ServerStart datetime2(0) = (SELECT sqlserver_start_time FROM sys.dm_os_sys_info);
  DECLARE @RunID       int;
  DECLARE @Db sysname, @Proc nvarchar(300), @Sql nvarchar(max), @Message nvarchar(max);

  IF @LogToTable = 'Y' AND OBJECT_ID('dbo.CompressionReviewRun') IS NULL
  BEGIN
    CREATE TABLE dbo.CompressionReviewRun (
      RunID     int IDENTITY(1,1) NOT NULL CONSTRAINT PK_CompressionReviewRun PRIMARY KEY,
      RunTime   datetime2(0) NOT NULL,
      Databases nvarchar(max) NULL,
      Flagged   int NOT NULL,
      Confirmed int NOT NULL
    );

    CREATE TABLE dbo.CompressionReviewLog (
      RunID           int           NOT NULL,
      DatabaseName    sysname       NOT NULL,
      SchemaName      sysname       NOT NULL,
      ObjectName      sysname       NOT NULL,
      IndexID         int           NOT NULL,
      IndexName       sysname       NULL,
      PartitionNumber int           NOT NULL,
      Compression     nvarchar(60)  NOT NULL,
      GB              decimal(9,2)  NOT NULL,
      StatsDays       decimal(9,1)  NOT NULL,
      UpdatePct       decimal(5,2)  NULL,
      UpdatesPerSec   decimal(12,3) NULL,
      Attempts        bigint        NULL,
      SuccessPct      decimal(5,2)  NULL,
      Suggestion      varchar(20)   NOT NULL,
      Confirmed       bit           NOT NULL,
      Reason          nvarchar(400) NOT NULL,
      Estimate        nvarchar(max) NOT NULL,
      CONSTRAINT PK_CompressionReviewLog PRIMARY KEY CLUSTERED
        (RunID, DatabaseName, SchemaName, ObjectName, IndexID, PartitionNumber)
    );
  END

  CREATE TABLE #Partitions (
    DatabaseName    sysname      NOT NULL,
    SchemaName      sysname      NOT NULL,
    ObjectName      sysname      NOT NULL,
    IndexID         int          NOT NULL,
    IndexName       sysname      NULL,
    PartitionNumber int          NOT NULL,
    Compression     nvarchar(60) NOT NULL,
    PageCount       bigint       NOT NULL,
    LeafUpdates     bigint       NULL,
    LeafOps         bigint       NULL,
    Attempts        bigint       NULL,
    Successes       bigint       NULL,
    StatsSince      datetime2(0) NULL
  );

  DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
    SELECT d.name
    FROM sys.databases d
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
      AND DATABASEPROPERTYEX(d.name, 'Updateability') = 'READ_WRITE'
      AND (@Databases = 'USER_DATABASES'
           OR d.name IN (SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Databases, ',')));

  OPEN dbs;
  FETCH NEXT FROM dbs INTO @Db;

  WHILE @@FETCH_STATUS = 0
  BEGIN
    SET @Sql = N'
      INSERT #Partitions (DatabaseName, SchemaName, ObjectName, IndexID, IndexName, PartitionNumber,
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
      SET @Message = 'Database ' + QUOTENAME(@Db) + ': ' + ERROR_MESSAGE();
      RAISERROR('%s', 10, 1, @Message) WITH NOWAIT;
    END CATCH

    FETCH NEXT FROM dbs INTO @Db;
  END

  CLOSE dbs;
  DEALLOCATE dbs;

  -- The counters of a partition start at the later of the server start and its last rebuild.
  -- ponytail: matched per index, not per partition - a rebuild of one partition shortens the
  -- window of the others too (rate overestimated); match PartitionNumber if partitioning appears.
  UPDATE #Partitions SET StatsSince = @ServerStart;

  IF OBJECT_ID('dbo.CommandLog') IS NOT NULL
    UPDATE p
       SET StatsSince = CASE WHEN l.LastRebuild > @ServerStart THEN l.LastRebuild ELSE @ServerStart END
      FROM #Partitions p
      CROSS APPLY (SELECT MAX(c.EndTime) AS LastRebuild
                   FROM dbo.CommandLog c
                   WHERE c.DatabaseName = p.DatabaseName COLLATE DATABASE_DEFAULT
                     AND c.SchemaName   = p.SchemaName   COLLATE DATABASE_DEFAULT
                     AND c.ObjectName   = p.ObjectName   COLLATE DATABASE_DEFAULT
                     AND ISNULL(c.IndexName, N'') = ISNULL(p.IndexName, N'') COLLATE DATABASE_DEFAULT
                     AND c.CommandType IN ('ALTER_INDEX', 'ALTER_TABLE')
                     AND c.Command LIKE '%REBUILD%'
                     AND c.ErrorNumber = 0) l;

  CREATE TABLE #Flagged (
    DatabaseName    sysname       NOT NULL,
    SchemaName      sysname       NOT NULL,
    ObjectName      sysname       NOT NULL,
    IndexID         int           NOT NULL,
    IndexName       sysname       NULL,
    PartitionNumber int           NOT NULL,
    Compression     nvarchar(60)  NOT NULL,
    GB              decimal(9,2)  NOT NULL,
    StatsDays       decimal(9,1)  NOT NULL,
    UpdatePct       decimal(5,2)  NULL,
    UpdatesPerSec   decimal(12,3) NULL,
    Attempts        bigint        NULL,
    SuccessPct      decimal(5,2)  NULL,
    Suggestion      varchar(20)   NOT NULL,
    Confirmed       bit           NOT NULL DEFAULT 0,
    Reason          nvarchar(400) NOT NULL,
    Estimate        nvarchar(max) NOT NULL
  );

  WITH m AS (
    SELECT *,
           DATEDIFF(SECOND, StatsSince, @Now)                                   AS WindowSec,
           CAST(100.0 * LeafUpdates / NULLIF(LeafOps, 0) AS decimal(5,2))       AS UpdatePct,
           CAST(1.0 * LeafUpdates / NULLIF(DATEDIFF(SECOND, StatsSince, @Now), 0) AS decimal(12,3)) AS UpdatesPerSec,
           CAST(100.0 * Successes / NULLIF(Attempts, 0) AS decimal(5,2))        AS SuccessPct
    FROM #Partitions
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
    WHERE WindowSec >= @MinStatsDays * 86400
  )
  INSERT #Flagged (DatabaseName, SchemaName, ObjectName, IndexID, IndexName, PartitionNumber, Compression,
                   GB, StatsDays, UpdatePct, UpdatesPerSec, Attempts, SuccessPct, Suggestion, Reason, Estimate)
  SELECT DatabaseName, SchemaName, ObjectName, IndexID, IndexName, PartitionNumber, Compression,
         CAST(PageCount * 8.0 / 1024 / 1024 AS decimal(9,2)),
         CAST(WindowSec / 86400.0 AS decimal(9,1)),
         UpdatePct, UpdatesPerSec, Attempts, SuccessPct, Suggestion, Reason,
         'EXEC ' + QUOTENAME(DatabaseName) + '.sys.sp_estimate_data_compression_savings '''
           + SchemaName + ''', ''' + ObjectName + ''', ' + CAST(IndexID AS varchar(10)) + ', '
           + CAST(PartitionNumber AS varchar(10)) + ', '''
           + CASE WHEN Compression = 'PAGE' THEN 'ROW' ELSE 'PAGE' END + ''';'
  FROM r
  WHERE Suggestion IS NOT NULL;

  DECLARE @Skipped int = (SELECT COUNT(*) FROM #Partitions
                          WHERE DATEDIFF(SECOND, StatsSince, @Now) < @MinStatsDays * 86400);

  IF @LogToTable = 'Y'
  BEGIN
    INSERT dbo.CompressionReviewRun (RunTime, Databases, Flagged, Confirmed)
    VALUES (@Now, @Databases, (SELECT COUNT(*) FROM #Flagged), 0);

    SET @RunID = SCOPE_IDENTITY();

    -- Confirmed = the same suggestion in each of the previous @ConfirmRuns - 1 runs as well.
    -- A run that flagged nothing still counts: it breaks the sequence.
    UPDATE f
       SET Confirmed = 1
      FROM #Flagged f
     WHERE @ConfirmRuns - 1 = (SELECT COUNT(*)
                               FROM (SELECT TOP (@ConfirmRuns - 1) RunID
                                     FROM dbo.CompressionReviewRun
                                     WHERE RunID < @RunID
                                     ORDER BY RunID DESC) prev
                               INNER JOIN dbo.CompressionReviewLog h
                                       ON h.RunID           = prev.RunID
                                      AND h.DatabaseName    = f.DatabaseName COLLATE DATABASE_DEFAULT
                                      AND h.SchemaName      = f.SchemaName   COLLATE DATABASE_DEFAULT
                                      AND h.ObjectName      = f.ObjectName   COLLATE DATABASE_DEFAULT
                                      AND h.IndexID         = f.IndexID
                                      AND h.PartitionNumber = f.PartitionNumber
                                      AND h.Suggestion      = f.Suggestion   COLLATE DATABASE_DEFAULT);

    INSERT dbo.CompressionReviewLog (RunID, DatabaseName, SchemaName, ObjectName, IndexID, IndexName,
                                  PartitionNumber, Compression, GB, StatsDays, UpdatePct, UpdatesPerSec,
                                  Attempts, SuccessPct, Suggestion, Confirmed, Reason, Estimate)
    SELECT @RunID, DatabaseName, SchemaName, ObjectName, IndexID, IndexName,
           PartitionNumber, Compression, GB, StatsDays, UpdatePct, UpdatesPerSec,
           Attempts, SuccessPct, Suggestion, Confirmed, Reason, Estimate
    FROM #Flagged;

    UPDATE dbo.CompressionReviewRun
       SET Confirmed = (SELECT COUNT(*) FROM #Flagged WHERE Confirmed = 1)
     WHERE RunID = @RunID;
  END

  SET @Message = 'Compressed partitions checked: ' + CAST((SELECT COUNT(*) FROM #Partitions) AS nvarchar(20))
               + ', skipped (stats window < ' + CAST(@MinStatsDays AS nvarchar(20)) + ' days): ' + CAST(@Skipped AS nvarchar(20))
               + ', flagged: ' + CAST((SELECT COUNT(*) FROM #Flagged) AS nvarchar(20))
               + CASE WHEN @LogToTable = 'Y'
                      THEN ', confirmed by ' + CAST(@ConfirmRuns AS nvarchar(20)) + ' runs in a row: '
                         + CAST((SELECT COUNT(*) FROM #Flagged WHERE Confirmed = 1) AS nvarchar(20))
                         + ' (RunID ' + CAST(@RunID AS nvarchar(20)) + ')'
                      ELSE ' (@LogToTable = N: no history, nothing is confirmed)' END;
  RAISERROR('%s', 10, 1, @Message) WITH NOWAIT;

  IF EXISTS (SELECT * FROM #Flagged)
    SELECT Confirmed, Suggestion, DatabaseName, SchemaName + '.' + ObjectName AS [Table],
           ISNULL(IndexName, '(heap)') AS [Index], PartitionNumber, GB, StatsDays,
           UpdatePct, UpdatesPerSec, Attempts, SuccessPct, Reason, Estimate
    FROM #Flagged
    ORDER BY Confirmed DESC, Suggestion, GB DESC;

  RETURN 0;
END
GO
