/*
====================================================================================================
  dbo.IndexCompression - a companion to Ola Hallengren's SQL Server Maintenance Solution

  Sets DATA_COMPRESSION on partitions that do not have it yet (data_compression = NONE).
  Idempotent: on a night when nothing has changed it finishes in seconds and does nothing.

  WHY, when IndexOptimize already has @DataCompression:
    - @DataCompression is one global value for the whole run; it overrides per-index
      decisions (PAGE for read-mostly tables, ROW for update-heavy ones);
    - the clause is only added on INDEX_REBUILD; an index whose fragmentation is below
      @FragmentationLevel1 is never touched and never gets compressed;
    - IndexOptimize does not process heaps (index_id = 0); this procedure does.

  PRINCIPLE: compression type is a property of the partition, and both REBUILD and REORGANIZE
  preserve it. Set it once - from then on IndexOptimize maintains it without @DataCompression.

  INSTALL: into the same database as IndexOptimize and CommandExecute (usually master).
  DEPENDENCIES: dbo.CommandExecute (logging to dbo.CommandLog with @LogToTable = 'Y').

  JOB ORDER: run this procedure BEFORE IndexOptimize. Compression is a rebuild, which also
  defragments, so IndexOptimize simply skips those indexes. The other way round you get
  two rebuilds instead of one.

  EXAMPLES:

    -- quick preview: candidate list and commands, no data is read
    EXECUTE dbo.IndexCompression
        @Databases = 'USER_DATABASES',
        @Execute = 'N';

    -- preview with savings figures: slow, reads a data sample into tempdb
    EXECUTE dbo.IndexCompression
        @Databases = 'USER_DATABASES',
        @EstimateSavings = 'Y',
        @Execute = 'N';

    -- nightly before IndexOptimize: pick up tables created since the last run
    EXECUTE dbo.IndexCompression
        @Databases = 'SalesDB',
        @DataCompression = 'AUTO',
        @SortInTempdb = 'Y',
        @TimeLimit = 3600,
        @LogToTable = 'Y';

    -- force PAGE on everything larger than 8 MB, no savings estimate
    EXECUTE dbo.IndexCompression
        @Databases = 'USER_DATABASES, -ReportsDB',
        @DataCompression = 'PAGE',
        @LogToTable = 'Y';

    -- initial rollout with hundreds of candidates: a one-off estimation pass without a time
    -- limit during a quiet period. Compresses nothing, only fills the estimate cache; the
    -- nightly job with the same @UseEstimateCache = 'Y' then spends its window on rebuilds.
    EXECUTE dbo.IndexCompression
        @Databases = 'SalesDB',
        @EstimateSavings = 'Y',
        @UseEstimateCache = 'Y',
        @Execute = 'N';

  PARAMETERS:
    @Databases        ALL_DATABASES | USER_DATABASES | SYSTEM_DATABASES | list of names,
                      exclusions with a dash: 'USER_DATABASES, -TempCopy'.
                      Wildcards are NOT supported.
    @DataCompression  AUTO (default) - decided per index from the estimated savings and
                      the update share;
                      PAGE / ROW - forced, no estimate, as in IndexOptimize.
                      NOTE on forced mode: compression does not always reduce size.
                      On narrow indexes over random binary(16) / uniqueidentifier keys PAGE
                      gives +10% instead of a saving: there is no redundancy in the data,
                      while the ROW-format overhead is added to every record.
                      AUTO filters such indexes out, forced mode does not.
    @MinNumberOfPages Minimum page count, 1000 (8 MB) - as in IndexOptimize.
    @MaxNumberOfPages Maximum page count, NULL = no limit.
    @EstimateSavings  Y/N, default NULL = 'Y' when @Execute = 'Y' and 'N' when @Execute = 'N'.
                      NOTE: sp_estimate_data_compression_savings reads a data sample into
                      tempdb - real load, not a dry run. That is why it is off by default in
                      preview mode; set @EstimateSavings = 'Y' explicitly to see the savings
                      without applying them. With 'N' the decision uses the update share only.
    @MinSavingsPct    Minimum saving required to compress. Default 25.
                      Also drives a free pre-filter for LOB-dominated objects: if the in-row
                      share is below this value, the maximum possible saving is below it too,
                      and the object is dropped before any estimate. At 25 that is everything
                      where LOB takes more than 75% of the space. AUTO mode only.
    @MaxUpdatePct     Above this update share PAGE is considered too expensive - ROW is used.
                      This is a ratio: on a nearly idle table it can still exceed the
                      threshold. Check the absolute rate before trusting a NONE decision.
    @EstimateMaxPages Objects larger than this are not estimated (sp_estimate copies a sample
                      into tempdb). Default 2560000 pages = 20 GB.
    @ExcludeObjects   List of LIKE patterns for table names: 'Staging%,%_Archive'.
    @UseSkipList      Y/N, default Y. An object found not worth compressing is written to
                      dbo.IndexCompressionSkipList and is no longer a candidate - it is not
                      re-estimated and does not appear in the report. Only written with
                      @Execute = 'Y': a preview leaves no side effects.
    @SkipListDays     After how many days a skip-list entry expires and the decision is
                      reviewed. Default 90.
    @SkipListGrowthPct If the object size changed by more than this percentage from the
                      recorded one, the decision is reviewed early. Default 50.

    View the list:   SELECT * FROM dbo.IndexCompressionSkipList ORDER BY PageCount DESC;
    Reset it:        TRUNCATE TABLE dbo.IndexCompressionSkipList;
    Remove one:      DELETE FROM dbo.IndexCompressionSkipList WHERE ObjectName = 'OrderLines';
    @UseEstimateCache Y/N, default N. For the initial rollout, when estimating all candidates
                      does not fit into @TimeLimit and every run re-estimates the same largest
                      objects without ever reaching execution.
                      Each estimate is written to dbo.IndexCompressionEstimateCache right away
                      and is not repeated. Savings percentages are stored, not decisions:
                      PAGE/ROW/NONE are recomputed from the current thresholds every time.
                      Entries expire by the same @SkipListDays and @SkipListGrowthPct. Written
                      with @Execute = 'N' too - to allow a separate estimation pass.
                      After the rollout: remove the parameter from the job and
                      DROP TABLE dbo.IndexCompressionEstimateCache; - with N the table is not
                      created, and the nightly estimate is fresh again.
    @TimeLimit        Seconds. No new command starts after the limit is reached.
    @Delay            Pause in seconds between commands.
    @FillFactor       1-100 or NULL (default). NULL = the rebuild uses the SERVER fill factor,
                      which is not visible in sys.indexes and may differ from 100.
                      Until the server setting is fixed (requires a restart) - pass 100.
    @WaitAtLowPriorityMinutes  MAX_DURATION for WAIT_AT_LOW_PRIORITY when @Online = 'Y'.
                      NULL = none: a queued Sch-M blocks every new query on the table while
                      it waits. Always set it on a live database.
    @AbortAfterWait   SELF (default) | BLOCKERS | NONE. SELF - the rebuild gives up quietly,
                      users do not notice; BLOCKERS kills the blocking sessions.
    @Online           Y/N, as in IndexOptimize, but for heaps as well. A heap or clustered index
                      in a table with image/text/ntext cannot be rebuilt ONLINE (Msg 2725):
                      those are skipped with a reason in the report and are not written to the
                      skip list - a run with @Online = 'N' in a maintenance window picks them up.
    The rest - as in IndexOptimize: @SortInTempdb, @MaxDOP, @LockTimeout,
    @LockMessageSeverity, @StringDelimiter, @LogToTable, @Execute.

  Source: independent work, compatible with the Ola Hallengren Maintenance Solution license
          (https://ola.hallengren.com/license.html) as a separate object.
====================================================================================================
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[IndexCompression]') AND type IN (N'P', N'PC'))
BEGIN
  EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [dbo].[IndexCompression] AS'
END
GO

ALTER PROCEDURE [dbo].[IndexCompression]

@Databases nvarchar(max) = NULL,
@DataCompression nvarchar(max) = 'AUTO',
@MinNumberOfPages int = 1000,
@MaxNumberOfPages int = NULL,
@EstimateSavings nvarchar(max) = NULL,
@MinSavingsPct int = 25,
@MaxUpdatePct int = 20,
@EstimateMaxPages int = 2560000,
@ExcludeObjects nvarchar(max) = NULL,
@UseSkipList nvarchar(max) = 'Y',
@SkipListDays int = 90,
@SkipListGrowthPct int = 50,
@UseEstimateCache nvarchar(max) = 'N',
@SortInTempdb nvarchar(max) = 'N',
@MaxDOP int = NULL,
@Online nvarchar(max) = 'N',
@FillFactor int = NULL,
@WaitAtLowPriorityMinutes int = NULL,
@AbortAfterWait nvarchar(10) = 'SELF',
@TimeLimit int = NULL,
@Delay int = NULL,
@LockTimeout int = NULL,
@LockMessageSeverity int = 16,
@StringDelimiter nvarchar(max) = ',',
@LogToTable nvarchar(max) = 'N',
@Execute nvarchar(max) = 'Y'

AS

BEGIN
  SET NOCOUNT ON;

  DECLARE @StartTime            datetime2 = SYSDATETIME();
  DECLARE @StartMessage         nvarchar(max);
  DECLARE @ErrorMessage         nvarchar(max);
  DECLARE @EmptyLine            nvarchar(max) = CHAR(9);
  DECLARE @Version              numeric(18,10);
  DECLARE @Build                int;
  DECLARE @EngineEdition        int;
  DECLARE @Errors               int = 0;
  DECLARE @ReturnCode           int = 0;
  DECLARE @SkipListExcluded     int = 0;
  DECLARE @LobExcluded          int = 0;
  DECLARE @CacheHits            int = 0;

  ----------------------------------------------------------------------------------------------------
  --// Persistent skip list                                                                       //--
  --// An object found not worth compressing is no longer a candidate and is not re-estimated     //--
  --// every night. An entry expires after @SkipListDays or when the object size changed by       //--
  --// more than @SkipListGrowthPct - then the decision is reviewed.                              //--
  ----------------------------------------------------------------------------------------------------

  IF OBJECT_ID('dbo.IndexCompressionSkipList') IS NULL
  BEGIN
    CREATE TABLE dbo.IndexCompressionSkipList (
      DatabaseName    sysname       NOT NULL,
      SchemaName      sysname       NOT NULL,
      ObjectName      sysname       NOT NULL,
      IndexID         int           NOT NULL,
      PartitionNumber int           NOT NULL,
      IndexName       sysname       NULL,
      PageCount       bigint        NOT NULL,
      LobPct          decimal(5,2)  NULL,
      SavePagePct     decimal(5,2)  NULL,
      SaveRowPct      decimal(5,2)  NULL,
      PctUpdate       decimal(5,2)  NULL,
      Reason          nvarchar(200) NULL,
      CreatedAt       datetime2     NOT NULL,
      CONSTRAINT PK_IndexCompressionSkipList PRIMARY KEY CLUSTERED
        (DatabaseName, SchemaName, ObjectName, IndexID, PartitionNumber)
    );
  END

  -- Estimate cache for the initial rollout, see @UseEstimateCache. Created on demand only:
  -- after the rollout DROP TABLE - and with N it does not come back.
  IF @UseEstimateCache = 'Y' AND OBJECT_ID('dbo.IndexCompressionEstimateCache') IS NULL
  BEGIN
    CREATE TABLE dbo.IndexCompressionEstimateCache (
      DatabaseName    sysname       NOT NULL,
      SchemaName      sysname       NOT NULL,
      ObjectName      sysname       NOT NULL,
      IndexID         int           NOT NULL,
      PartitionNumber int           NOT NULL,
      PageCount       bigint        NOT NULL,
      SavePagePct     decimal(5,2)  NULL,
      SaveRowPct      decimal(5,2)  NULL,
      CreatedAt       datetime2     NOT NULL,
      CONSTRAINT PK_IndexCompressionEstimateCache PRIMARY KEY CLUSTERED
        (DatabaseName, SchemaName, ObjectName, IndexID, PartitionNumber)
    );
  END

  SET @Version = CAST(LEFT(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(max)),
                      CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(max))) - 1) AS int);
  SET @Build = CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(max)), 2) AS int);
  SET @EngineEdition = CAST(SERVERPROPERTY('EngineEdition') AS int);

  ----------------------------------------------------------------------------------------------------
  --// Check input parameters                                                                     //--
  ----------------------------------------------------------------------------------------------------

  IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID('dbo.CommandExecute') AND type = 'P')
  BEGIN
    SET @ErrorMessage = 'The stored procedure dbo.CommandExecute is missing. Install the Ola Hallengren Maintenance Solution into this database.';
    RAISERROR('%s', 16, 1, @ErrorMessage) WITH NOWAIT;
    SET @Errors = @Errors + 1;
  END

  -- Data compression: Enterprise/Developer, Azure, or any edition from SQL Server 2016 SP1
  IF NOT (@EngineEdition IN (3, 5, 8) OR @Version > 13 OR (@Version = 13 AND @Build >= 4001))
  BEGIN
    SET @ErrorMessage = 'This SQL Server edition does not support data compression.';
    RAISERROR('%s', 16, 1, @ErrorMessage) WITH NOWAIT;
    SET @Errors = @Errors + 1;
  END

  IF @Databases IS NULL OR @Databases = ''
  BEGIN
    SET @ErrorMessage = 'The parameter @Databases is required. Examples: USER_DATABASES, ALL_DATABASES, ''MyDb, -Other''.';
    RAISERROR('%s', 16, 1, @ErrorMessage) WITH NOWAIT;
    SET @Errors = @Errors + 1;
  END

  IF @DataCompression IS NULL OR @DataCompression NOT IN ('AUTO', 'PAGE', 'ROW')
  BEGIN
    SET @ErrorMessage = 'The value for the parameter @DataCompression is not supported. Supported: AUTO, PAGE, ROW.';
    RAISERROR('%s', 16, 1, @ErrorMessage) WITH NOWAIT;
    SET @Errors = @Errors + 1;
  END

  IF @SortInTempdb NOT IN ('Y', 'N') OR @Online NOT IN ('Y', 'N')
     OR @LogToTable NOT IN ('Y', 'N') OR @Execute NOT IN ('Y', 'N')
     OR @UseSkipList NOT IN ('Y', 'N') OR @UseEstimateCache NOT IN ('Y', 'N')
     OR (@EstimateSavings IS NOT NULL AND @EstimateSavings NOT IN ('Y', 'N'))
  BEGIN
    SET @ErrorMessage = 'The parameters @EstimateSavings, @UseSkipList, @UseEstimateCache, @SortInTempdb, @Online, @LogToTable, @Execute accept Y or N.';
    RAISERROR('%s', 16, 1, @ErrorMessage) WITH NOWAIT;
    SET @Errors = @Errors + 1;
  END

  IF @AbortAfterWait NOT IN ('SELF', 'BLOCKERS', 'NONE')
  BEGIN
    SET @ErrorMessage = 'The parameter @AbortAfterWait accepts SELF, BLOCKERS or NONE.';
    RAISERROR('%s', 16, 1, @ErrorMessage) WITH NOWAIT;
    SET @Errors = @Errors + 1;
  END

  IF @FillFactor IS NOT NULL AND (@FillFactor < 1 OR @FillFactor > 100)
  BEGIN
    SET @ErrorMessage = 'The parameter @FillFactor accepts 1-100.';
    RAISERROR('%s', 16, 1, @ErrorMessage) WITH NOWAIT;
    SET @Errors = @Errors + 1;
  END

  -- The savings estimate READS DATA, it is not a dry run. By default it runs only with
  -- @Execute = 'Y'. To get savings figures in preview mode, set @EstimateSavings = 'Y'
  -- explicitly.
  IF @EstimateSavings IS NULL
    SET @EstimateSavings = CASE WHEN @Execute = 'Y' THEN 'Y' ELSE 'N' END;

  IF @Online = 'Y' AND @EngineEdition NOT IN (3, 5, 8)
  BEGIN
    SET @ErrorMessage = '@Online = Y requires Enterprise, Developer or Azure. Continuing OFFLINE.';
    RAISERROR('%s', 10, 1, @ErrorMessage) WITH NOWAIT;
    SET @Online = 'N';
  END

  IF @Errors > 0 RETURN 1;

  SET @StartMessage = 'Date and time: ' + CONVERT(nvarchar(max), @StartTime, 120)
                    + ', Compression: ' + @DataCompression
                    + ', Execute: ' + @Execute;
  RAISERROR('%s', 10, 1, @StartMessage) WITH NOWAIT;
  RAISERROR(@EmptyLine, 10, 1) WITH NOWAIT;

  ----------------------------------------------------------------------------------------------------
  --// Select databases                                                                           //--
  ----------------------------------------------------------------------------------------------------

  CREATE TABLE #Tokens (Token nvarchar(max), Exclude bit);

  DECLARE @List nvarchar(max) = @Databases, @Token nvarchar(max), @Pos int;

  WHILE LEN(ISNULL(@List, '')) > 0
  BEGIN
    SET @Pos = CHARINDEX(@StringDelimiter, @List);

    IF @Pos = 0
    BEGIN
      SET @Token = @List;
      SET @List = N'';
    END
    ELSE
    BEGIN
      SET @Token = LEFT(@List, @Pos - 1);
      SET @List = SUBSTRING(@List, @Pos + LEN(@StringDelimiter), LEN(@List));
    END

    SET @Token = LTRIM(RTRIM(@Token));
    IF @Token <> N''
      INSERT #Tokens (Token, Exclude)
      VALUES (CASE WHEN LEFT(@Token, 1) = N'-' THEN STUFF(@Token, 1, 1, N'') ELSE @Token END,
              CASE WHEN LEFT(@Token, 1) = N'-' THEN 1 ELSE 0 END);
  END

  CREATE TABLE #Databases (DatabaseName sysname PRIMARY KEY, Processed bit NOT NULL DEFAULT 0);

  INSERT #Databases (DatabaseName)
  SELECT d.name
  FROM sys.databases d
  WHERE d.database_id <> 2                                              -- tempdb
    AND d.state_desc = 'ONLINE'
    AND DATABASEPROPERTYEX(d.name, 'Updateability') = 'READ_WRITE'      -- filters out readable secondaries
    AND EXISTS (SELECT * FROM #Tokens t WHERE t.Exclude = 0
                  AND (t.Token = 'ALL_DATABASES'
                    OR (t.Token = 'SYSTEM_DATABASES' AND d.database_id IN (1, 3, 4))
                    OR (t.Token = 'USER_DATABASES'   AND d.database_id NOT IN (1, 2, 3, 4))
                    OR  t.Token = d.name))
    AND NOT EXISTS (SELECT * FROM #Tokens t WHERE t.Exclude = 1
                  AND (t.Token = 'ALL_DATABASES'
                    OR (t.Token = 'SYSTEM_DATABASES' AND d.database_id IN (1, 3, 4))
                    OR (t.Token = 'USER_DATABASES'   AND d.database_id NOT IN (1, 2, 3, 4))
                    OR  t.Token = d.name));

  IF NOT EXISTS (SELECT * FROM #Databases)
  BEGIN
    SET @ErrorMessage = 'No accessible database matches the value of @Databases.';
    RAISERROR('%s', 16, 1, @ErrorMessage) WITH NOWAIT;
    RETURN 1;
  END

  ----------------------------------------------------------------------------------------------------
  --// Collect objects                                                                            //--
  ----------------------------------------------------------------------------------------------------

  CREATE TABLE #Objects (
    ID              int IDENTITY(1,1) PRIMARY KEY,
    DatabaseName    sysname       NOT NULL,
    SchemaName      sysname       NOT NULL,
    ObjectName      sysname       NOT NULL,
    IndexID         int           NOT NULL,
    IndexName       sysname       NULL,
    IndexType       int           NOT NULL,
    IsImageText     bit           NOT NULL DEFAULT 0,
    PartitionNumber int           NOT NULL,
    PartitionCount  int           NOT NULL,
    PageCount       bigint        NOT NULL,
    LobPages        bigint        NULL,
    TablePages      bigint        NULL,
    PctUpdate       decimal(5,2)  NULL,
    PctScan         decimal(5,2)  NULL,
    EstCurKB        bigint        NULL,
    EstPageKB       bigint        NULL,
    EstRowKB        bigint        NULL,
    SavePagePct     decimal(5,2)  NULL,
    SaveRowPct      decimal(5,2)  NULL,
    EstStatus       varchar(10)   NULL,
    Decision        varchar(10)   NULL,
    Reason          nvarchar(200) NULL,
    Status          varchar(10)   NOT NULL DEFAULT 'PENDING'  -- PENDING/OK/SKIPPED/ERROR
  );

  DECLARE @CurrentDatabaseName sysname, @SP nvarchar(max), @Stmt nvarchar(max);

  WHILE 1 = 1
  BEGIN
    SELECT TOP 1 @CurrentDatabaseName = DatabaseName FROM #Databases WHERE Processed = 0 ORDER BY DatabaseName;
    IF @@ROWCOUNT = 0 BREAK;

    SET @SP = QUOTENAME(@CurrentDatabaseName) + N'.sys.sp_executesql';

    -- Runs in the context of the target database: the DMVs below are database-scoped.
    SET @Stmt = N'
      INSERT INTO #Objects (DatabaseName, SchemaName, ObjectName, IndexID, IndexName, IndexType, IsImageText,
                            PartitionNumber, PartitionCount, PageCount, LobPages, PctUpdate, PctScan)
      SELECT @Db, s.name, t.name, i.index_id, i.name, i.type,
             -- like IsImageText in IndexOptimize, plus heaps: a heap and a clustered index carry
             -- all columns of the table, and with image/text/ntext among them an ONLINE rebuild
             -- is impossible (Msg 2725)
             CASE WHEN i.[type] IN (0, 1) AND EXISTS (SELECT * FROM sys.columns c
                                                       WHERE c.[object_id] = t.[object_id]
                                                         AND TYPE_NAME(c.system_type_id) IN (''image'', ''text'', ''ntext''))
                  THEN 1 ELSE 0 END,
             p.partition_number,
             -- the real partition count, not the number of partitions that passed the filter:
             -- otherwise a partitioned index with a single matching partition would get
             -- PARTITION = ALL and the command would touch the rest
             (SELECT COUNT(*) FROM sys.partitions p2
               WHERE p2.[object_id] = i.[object_id] AND p2.index_id = i.index_id),
             ps.used_page_count,
             -- LOB and row-overflow pages: compression does not touch them at all
             ps.lob_used_page_count + ps.row_overflow_used_page_count,
             CAST(100.0 * os.leaf_update_count / NULLIF(os.leaf_insert_count + os.leaf_update_count
                  + os.leaf_delete_count + os.leaf_page_merge_count + os.range_scan_count
                  + os.singleton_lookup_count, 0) AS decimal(5,2)),
             CAST(100.0 * os.range_scan_count / NULLIF(os.leaf_insert_count + os.leaf_update_count
                  + os.leaf_delete_count + os.leaf_page_merge_count + os.range_scan_count
                  + os.singleton_lookup_count, 0) AS decimal(5,2))
      FROM sys.tables t
      INNER JOIN sys.schemas s ON s.[schema_id] = t.[schema_id]
      INNER JOIN sys.indexes i ON i.[object_id] = t.[object_id]
      INNER JOIN sys.partitions p ON p.[object_id] = i.[object_id] AND p.index_id = i.index_id
      INNER JOIN sys.dm_db_partition_stats ps ON ps.[object_id] = p.[object_id]
                                             AND ps.index_id = p.index_id
                                             AND ps.partition_id = p.partition_id
      LEFT JOIN sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) os
                                              ON os.[object_id] = p.[object_id]
                                             AND os.index_id = p.index_id
                                             AND os.partition_number = p.partition_number
      WHERE t.is_ms_shipped = 0
        AND i.[type] IN (0, 1, 2)
        AND i.is_disabled = 0
        AND i.is_hypothetical = 0
        AND p.data_compression = 0
        AND ISNULL(OBJECTPROPERTY(t.[object_id], ''TableIsMemoryOptimized''), 0) = 0
        AND NOT EXISTS (SELECT * FROM sys.columns c
                        WHERE c.[object_id] = t.[object_id]
                          AND (c.is_sparse = 1 OR c.is_column_set = 1))
        AND ps.used_page_count >= @MinPages
        AND (@MaxPages IS NULL OR ps.used_page_count <= @MaxPages);';

    BEGIN TRY
      EXECUTE @SP @stmt = @Stmt,
                  @params = N'@Db sysname, @MinPages int, @MaxPages int',
                  @Db = @CurrentDatabaseName,
                  @MinPages = @MinNumberOfPages,
                  @MaxPages = @MaxNumberOfPages;
    END TRY
    BEGIN CATCH
      SET @ErrorMessage = 'Database ' + QUOTENAME(@CurrentDatabaseName) + ': ' + ERROR_MESSAGE();
      RAISERROR('%s', 16, 1, @ErrorMessage) WITH NOWAIT;
    END CATCH

    UPDATE #Databases SET Processed = 1 WHERE DatabaseName = @CurrentDatabaseName;
  END

  -- Exclusions by table name patterns
  IF @ExcludeObjects IS NOT NULL AND @ExcludeObjects <> ''
  BEGIN
    SET @List = @ExcludeObjects;

    WHILE LEN(ISNULL(@List, '')) > 0
    BEGIN
      SET @Pos = CHARINDEX(@StringDelimiter, @List);

      IF @Pos = 0 BEGIN SET @Token = @List; SET @List = N''; END
      ELSE
      BEGIN
        SET @Token = LEFT(@List, @Pos - 1);
        SET @List = SUBSTRING(@List, @Pos + LEN(@StringDelimiter), LEN(@List));
      END

      SET @Token = LTRIM(RTRIM(@Token));
      IF @Token <> N'' DELETE FROM #Objects WHERE ObjectName LIKE @Token;
    END
  END

  -- Free pre-filter for LOB-dominated objects, BEFORE any estimate.
  -- Compression only works on in-row data, so the upper bound of the saving for an object
  -- equals its in-row share (the case where it would compress to zero). If even that bound
  -- is below @MinSavingsPct, the estimate result is known in advance - and the decision
  -- needs neither computing nor remembering: it is derived from metadata every time.
  -- No separate threshold is needed: it follows from @MinSavingsPct.
  IF @DataCompression = 'AUTO'
  BEGIN
    DELETE FROM #Objects
    WHERE 100.0 * (PageCount - ISNULL(LobPages, 0)) / NULLIF(PageCount, 0) < @MinSavingsPct;

    SET @LobExcluded = @@ROWCOUNT;
  END

  -- Skip-list exclusions - BEFORE the estimation phase, otherwise pointless:
  -- the estimate is exactly the work that should not be repeated every night.
  IF @UseSkipList = 'Y'
  BEGIN
    DELETE o
    FROM #Objects o
    INNER JOIN dbo.IndexCompressionSkipList sl
            ON sl.DatabaseName    = o.DatabaseName
           AND sl.SchemaName      = o.SchemaName
           AND sl.ObjectName      = o.ObjectName
           AND sl.IndexID         = o.IndexID
           AND sl.PartitionNumber = o.PartitionNumber
    WHERE DATEDIFF(DAY, sl.CreatedAt, SYSDATETIME()) < @SkipListDays
      AND ABS(o.PageCount - sl.PageCount) * 100.0 / NULLIF(sl.PageCount, 0) < @SkipListGrowthPct;

    SET @SkipListExcluded = @@ROWCOUNT;
  END

  -- Estimate cache: what a previous run estimated is not estimated again. Percentages are
  -- taken, not decisions - PAGE/ROW/NONE below are computed from the current thresholds.
  -- Validity follows the same rules as the skip list. Plus one: an entry without a ROW
  -- estimate is not usable for an object that is now updated more often than @MaxUpdatePct -
  -- the decision then relies on ROW, and without it would fall to NONE for no reason.
  IF @UseEstimateCache = 'Y' AND @DataCompression = 'AUTO'
  BEGIN
    UPDATE o
       SET SavePagePct = c.SavePagePct,
           SaveRowPct  = c.SaveRowPct,
           EstStatus   = 'OK'
      FROM #Objects o
      INNER JOIN dbo.IndexCompressionEstimateCache c
              ON c.DatabaseName    = o.DatabaseName
             AND c.SchemaName      = o.SchemaName
             AND c.ObjectName      = o.ObjectName
             AND c.IndexID         = o.IndexID
             AND c.PartitionNumber = o.PartitionNumber
     WHERE DATEDIFF(DAY, c.CreatedAt, SYSDATETIME()) < @SkipListDays
       AND ABS(o.PageCount - c.PageCount) * 100.0 / NULLIF(c.PageCount, 0) < @SkipListGrowthPct
       AND (c.SaveRowPct IS NOT NULL OR ISNULL(o.PctUpdate, 0) <= @MaxUpdatePct);

    SET @CacheHits = @@ROWCOUNT;
  END

  UPDATE o
     SET TablePages = x.TotalPages
    FROM #Objects o
    INNER JOIN (SELECT DatabaseName, SchemaName, ObjectName, SUM(PageCount) AS TotalPages
                FROM #Objects GROUP BY DatabaseName, SchemaName, ObjectName) x
            ON x.DatabaseName = o.DatabaseName
           AND x.SchemaName   = o.SchemaName
           AND x.ObjectName   = o.ObjectName;

  SET @StartMessage = 'Compression candidates: ' + CAST((SELECT COUNT(*) FROM #Objects) AS nvarchar(max))
                    + ' (' + CAST((SELECT ISNULL(SUM(PageCount), 0) * 8 / 1024 FROM #Objects) AS nvarchar(max)) + ' MB)'
                    + CASE WHEN @LobExcluded > 0
                           THEN ', filtered out as LOB-dominated: ' + CAST(@LobExcluded AS nvarchar(max))
                           ELSE '' END
                    + CASE WHEN @SkipListExcluded > 0
                           THEN ', excluded by skip list: ' + CAST(@SkipListExcluded AS nvarchar(max))
                              + ' (dbo.IndexCompressionSkipList)'
                           ELSE '' END
                    + CASE WHEN @CacheHits > 0
                           THEN ', estimates from cache: ' + CAST(@CacheHits AS nvarchar(max))
                              + ' (dbo.IndexCompressionEstimateCache)'
                           ELSE '' END;
  RAISERROR('%s', 10, 1, @StartMessage) WITH NOWAIT;
  RAISERROR(@EmptyLine, 10, 1) WITH NOWAIT;

  ----------------------------------------------------------------------------------------------------
  --// Savings estimate (AUTO only)                                                               //--
  ----------------------------------------------------------------------------------------------------

  DECLARE @ID int, @CurrentSchemaName sysname, @CurrentObjectName sysname,
          @CurrentIndexID int, @CurrentIndexName sysname, @CurrentIndexType int,
          @CurrentPartitionNumber int, @CurrentPartitionCount int,
          @CurrentPageCount bigint, @CurrentPctUpdate decimal(5,2),
          @CurrentDecision varchar(10), @CurrentCommandType nvarchar(60),
          @CurrentIsImageText bit,
          @Command nvarchar(max), @Comment nvarchar(max);

  CREATE TABLE #Est (ObjectName sysname, SchemaName sysname, IndexID int, PartitionNumber int,
                     CurKB bigint, ReqKB bigint, SampleCurKB bigint, SampleReqKB bigint);

  IF @DataCompression = 'AUTO' AND @EstimateSavings = 'Y'
  BEGIN
    UPDATE #Objects SET EstStatus = 'SKIP' WHERE PageCount > @EstimateMaxPages AND EstStatus IS NULL;

    SET @StartMessage = 'Estimation phase: ' + CAST((SELECT COUNT(*) FROM #Objects WHERE EstStatus IS NULL) AS nvarchar(max))
                      + ' objects. sp_estimate_data_compression_savings reads a data sample into tempdb - '
                      + 'this costs I/O and time regardless of @Execute. To turn it off: @EstimateSavings = ''N''.';
    RAISERROR('%s', 10, 1, @StartMessage) WITH NOWAIT;
    RAISERROR(@EmptyLine, 10, 1) WITH NOWAIT;

    WHILE 1 = 1
    BEGIN
      IF @TimeLimit IS NOT NULL AND DATEDIFF(SECOND, @StartTime, SYSDATETIME()) > @TimeLimit
      BEGIN
        UPDATE #Objects SET EstStatus = 'SKIP' WHERE EstStatus IS NULL;
        RAISERROR('Time limit reached during the estimation phase.', 10, 1) WITH NOWAIT;
        BREAK;
      END

      SELECT TOP 1 @ID = ID, @CurrentDatabaseName = DatabaseName, @CurrentSchemaName = SchemaName,
                   @CurrentObjectName = ObjectName, @CurrentIndexID = IndexID,
                   @CurrentPartitionNumber = PartitionNumber, @CurrentPctUpdate = PctUpdate,
                   @CurrentPageCount = PageCount
      FROM #Objects WHERE EstStatus IS NULL ORDER BY PageCount DESC;

      IF @@ROWCOUNT = 0 BREAK;

      SET @StartMessage = 'Estimating: ' + QUOTENAME(@CurrentSchemaName) + '.' + QUOTENAME(@CurrentObjectName)
                        + ' index_id ' + CAST(@CurrentIndexID AS nvarchar(max))
                        + ' (' + CAST(@CurrentPageCount * 8 / 1024 AS nvarchar(max)) + ' MB)';
      RAISERROR('%s', 10, 1, @StartMessage) WITH NOWAIT;

      SET @Stmt = N'EXEC ' + QUOTENAME(@CurrentDatabaseName)
                + N'.sys.sp_estimate_data_compression_savings @s, @t, @i, @p, @c';

      BEGIN TRY
        DELETE FROM #Est;

        INSERT #Est
        EXECUTE sys.sp_executesql @Stmt,
                N'@s sysname, @t sysname, @i int, @p int, @c nvarchar(10)',
                @s = @CurrentSchemaName, @t = @CurrentObjectName, @i = @CurrentIndexID,
                @p = @CurrentPartitionNumber, @c = 'PAGE';

        UPDATE o
           SET EstCurKB    = e.CurKB,
               EstPageKB   = e.ReqKB,
               SavePagePct = CAST(100.0 * (e.CurKB - e.ReqKB) / NULLIF(e.CurKB, 0) AS decimal(5,2)),
               EstStatus   = 'OK'
          FROM #Objects o CROSS APPLY (SELECT TOP 1 CurKB, ReqKB FROM #Est) e
         WHERE o.ID = @ID;

        -- ROW is estimated only where PAGE is in doubt because of frequent updates
        IF ISNULL(@CurrentPctUpdate, 0) > @MaxUpdatePct
        BEGIN
          DELETE FROM #Est;

          INSERT #Est
          EXECUTE sys.sp_executesql @Stmt,
                  N'@s sysname, @t sysname, @i int, @p int, @c nvarchar(10)',
                  @s = @CurrentSchemaName, @t = @CurrentObjectName, @i = @CurrentIndexID,
                  @p = @CurrentPartitionNumber, @c = 'ROW';

          UPDATE o
             SET EstRowKB   = e.ReqKB,
                 SaveRowPct = CAST(100.0 * (e.CurKB - e.ReqKB) / NULLIF(e.CurKB, 0) AS decimal(5,2))
            FROM #Objects o CROSS APPLY (SELECT TOP 1 CurKB, ReqKB FROM #Est) e
           WHERE o.ID = @ID;
        END
      END TRY
      BEGIN CATCH
        SET @ErrorMessage = 'Estimate ' + QUOTENAME(@CurrentObjectName) + ': ' + ERROR_MESSAGE();
        RAISERROR('%s', 10, 1, @ErrorMessage) WITH NOWAIT;
        UPDATE #Objects SET EstStatus = 'ERROR' WHERE ID = @ID;
      END CATCH

      -- Right away, not at the end: a time-limit stop or a cancelled job does not lose the work.
      IF @UseEstimateCache = 'Y'
      BEGIN
        DELETE FROM dbo.IndexCompressionEstimateCache
         WHERE DatabaseName = @CurrentDatabaseName AND SchemaName = @CurrentSchemaName
           AND ObjectName = @CurrentObjectName AND IndexID = @CurrentIndexID
           AND PartitionNumber = @CurrentPartitionNumber;

        INSERT dbo.IndexCompressionEstimateCache
              (DatabaseName, SchemaName, ObjectName, IndexID, PartitionNumber,
               PageCount, SavePagePct, SaveRowPct, CreatedAt)
        SELECT DatabaseName, SchemaName, ObjectName, IndexID, PartitionNumber,
               PageCount, SavePagePct, SaveRowPct, SYSDATETIME()
        FROM #Objects
        WHERE ID = @ID AND EstStatus = 'OK';
      END
    END
  END

  ----------------------------------------------------------------------------------------------------
  --// Decision per object                                                                        //--
  ----------------------------------------------------------------------------------------------------

  UPDATE #Objects
     SET Decision =
         CASE
           -- explicit mode: forced, as in IndexOptimize
           WHEN @DataCompression IN ('PAGE', 'ROW') THEN @DataCompression
           -- no estimate: decide by the workload profile
           WHEN ISNULL(EstStatus, 'SKIP') <> 'OK'
                THEN CASE WHEN ISNULL(PctUpdate, 0) <= @MaxUpdatePct THEN 'PAGE' ELSE 'ROW' END
           -- the saving is not worth a rebuild
           WHEN SavePagePct < @MinSavingsPct AND ISNULL(SaveRowPct, 0) < @MinSavingsPct THEN 'NONE'
           -- update-heavy: PAGE is CPU-expensive, take ROW if it gives anything
           WHEN ISNULL(PctUpdate, 0) > @MaxUpdatePct
                THEN CASE WHEN ISNULL(SaveRowPct, 0) >= @MinSavingsPct THEN 'ROW' ELSE 'NONE' END
           ELSE 'PAGE'
         END,
       Reason =
         CASE
           WHEN @DataCompression IN ('PAGE', 'ROW') THEN N'set by @DataCompression'
           WHEN ISNULL(EstStatus, 'SKIP') = 'SKIP'
                THEN N'not estimated (above @EstimateMaxPages or @EstimateSavings = N), updates '
                     + CAST(ISNULL(PctUpdate, 0) AS nvarchar(20)) + N'%'
           WHEN EstStatus = 'ERROR' THEN N'estimate failed, decision by update share'
           -- LOB is checked FIRST: a table with blobs also shows a near-zero saving,
           -- but for a completely different reason than incompressible keys - do not mix them.
           WHEN SavePagePct < @MinSavingsPct AND ISNULL(SaveRowPct, 0) < @MinSavingsPct
                AND 100.0 * ISNULL(LobPages, 0) / NULLIF(PageCount, 0) >= 50
                THEN CAST(CAST(100.0 * LobPages / PageCount AS decimal(5,2)) AS nvarchar(20))
                     + N'% of the space is LOB data, which compression does not touch. In-row saving: '
                     + CAST(ISNULL(SavePagePct, 0) AS nvarchar(20)) + N'%'
           -- Compression increases the size instead of reducing it. Typically narrow indexes
           -- over random binary(16) / uniqueidentifier keys: there is no redundancy, while the
           -- ROW-format overhead is added to every record.
           WHEN SavePagePct <= 0 AND ISNULL(SaveRowPct, 0) <= 0
                THEN N'compression would INCREASE the size by ' + CAST(ABS(SavePagePct) AS nvarchar(20))
                     + N'%: incompressible data, format overhead exceeds the gain'
           WHEN SavePagePct < @MinSavingsPct AND ISNULL(SaveRowPct, 0) < @MinSavingsPct
                THEN N'saving only ' + CAST(ISNULL(SavePagePct, 0) AS nvarchar(20))
                     + N'% - below @MinSavingsPct'
           WHEN ISNULL(PctUpdate, 0) > @MaxUpdatePct AND ISNULL(SaveRowPct, 0) < @MinSavingsPct
                THEN N'updates ' + CAST(PctUpdate AS nvarchar(20)) + N'% and ROW saves only '
                     + CAST(ISNULL(SaveRowPct, 0) AS nvarchar(20)) + N'%'
           WHEN ISNULL(PctUpdate, 0) > @MaxUpdatePct
                THEN N'updates ' + CAST(PctUpdate AS nvarchar(20)) + N'%, ROW saves '
                     + CAST(SaveRowPct AS nvarchar(20)) + N'%'
           ELSE N'saving ' + CAST(SavePagePct AS nvarchar(20)) + N'%'
         END;

  -- Mark, do not delete: otherwise the object disappears from the report and it is unclear
  -- why it stays uncompressed after this run.
  UPDATE #Objects SET Status = 'SKIPPED' WHERE Decision = 'NONE';

  -- The skip list is updated only on a real run: a preview must not leave side effects.
  IF @UseSkipList = 'Y' AND @Execute = 'Y'
  BEGIN
    DELETE sl
    FROM dbo.IndexCompressionSkipList sl
    INNER JOIN #Objects o
            ON o.DatabaseName    = sl.DatabaseName
           AND o.SchemaName      = sl.SchemaName
           AND o.ObjectName      = sl.ObjectName
           AND o.IndexID         = sl.IndexID
           AND o.PartitionNumber = sl.PartitionNumber;

    INSERT dbo.IndexCompressionSkipList
          (DatabaseName, SchemaName, ObjectName, IndexID, PartitionNumber, IndexName,
           PageCount, LobPct, SavePagePct, SaveRowPct, PctUpdate, Reason, CreatedAt)
    SELECT DatabaseName, SchemaName, ObjectName, IndexID, PartitionNumber, IndexName,
           PageCount,
           CAST(100.0 * ISNULL(LobPages, 0) / NULLIF(PageCount, 0) AS decimal(5,2)),
           SavePagePct, SaveRowPct, PctUpdate, Reason, SYSDATETIME()
    FROM #Objects
    WHERE Decision = 'NONE';
  END

  ----------------------------------------------------------------------------------------------------
  --// Execute commands                                                                           //--
  ----------------------------------------------------------------------------------------------------

  WHILE 1 = 1
  BEGIN
    IF @TimeLimit IS NOT NULL AND DATEDIFF(SECOND, @StartTime, SYSDATETIME()) > @TimeLimit
    BEGIN
      RAISERROR('Time limit reached. The remaining objects are left for the next run.', 10, 1) WITH NOWAIT;
      BREAK;
    END

    -- A heap goes before its nonclustered indexes: its rebuild rebuilds them again.
    SELECT TOP 1 @ID = ID, @CurrentDatabaseName = DatabaseName, @CurrentSchemaName = SchemaName,
                 @CurrentObjectName = ObjectName, @CurrentIndexID = IndexID,
                 @CurrentIndexName = IndexName, @CurrentIndexType = IndexType,
                 @CurrentPartitionNumber = PartitionNumber, @CurrentPartitionCount = PartitionCount,
                 @CurrentPageCount = PageCount, @CurrentDecision = Decision,
                 @CurrentIsImageText = IsImageText
    FROM #Objects WHERE Status = 'PENDING' ORDER BY TablePages DESC, ObjectName, IndexID;

    IF @@ROWCOUNT = 0 BREAK;

    -- A table with image/text/ntext cannot be rebuilt ONLINE (Msg 2725), and going offline
    -- instead means Sch-M for the whole rebuild without WAIT_AT_LOW_PRIORITY. Hence a skip with
    -- a reason: not written to the skip list, a run with @Online = 'N' in a window compresses it.
    IF @Online = 'Y' AND @CurrentIsImageText = 1
    BEGIN
      UPDATE #Objects
         SET Status = 'SKIPPED',
             Reason = N'image/text/ntext: ONLINE is not possible (Msg 2725), a run with @Online = N compresses it'
       WHERE ID = @ID;
      CONTINUE;
    END

    SET @CurrentCommandType = CASE WHEN @CurrentIndexID = 0 THEN 'ALTER_TABLE' ELSE 'ALTER_INDEX' END;

    SET @Command = CASE WHEN @LockTimeout IS NOT NULL
                        THEN 'SET LOCK_TIMEOUT ' + CAST(@LockTimeout * 1000 AS nvarchar(max)) + '; '
                        ELSE '' END
                 + CASE WHEN @CurrentIndexID = 0
                        THEN 'ALTER TABLE ' + QUOTENAME(@CurrentSchemaName) + '.' + QUOTENAME(@CurrentObjectName)
                        ELSE 'ALTER INDEX ' + QUOTENAME(@CurrentIndexName) + ' ON '
                           + QUOTENAME(@CurrentSchemaName) + '.' + QUOTENAME(@CurrentObjectName) END
                 + ' REBUILD PARTITION = '
                 + CASE WHEN @CurrentPartitionCount > 1
                        THEN CAST(@CurrentPartitionNumber AS nvarchar(max)) ELSE 'ALL' END
                 + ' WITH (DATA_COMPRESSION = ' + @CurrentDecision
                 -- ALTER TABLE ... REBUILD of a heap accepts both ONLINE and SORT_IN_TEMPDB, but the
                 -- latter is ignored for the heap itself with a warning - so SORT_IN_TEMPDB for indexes only
                 + CASE WHEN @SortInTempdb = 'Y' AND @CurrentIndexID > 0 THEN ', SORT_IN_TEMPDB = ON' ELSE '' END
                 -- FILLFACTOR: without it the rebuild uses the SERVER value, which is not
                 -- visible in sys.indexes and may differ from 100. An explicit 100 protects
                 -- against that until the server setting is fixed (requires a restart).
                 + CASE WHEN @FillFactor IS NOT NULL AND @CurrentIndexID > 0
                        THEN ', FILLFACTOR = ' + CAST(@FillFactor AS nvarchar(max)) ELSE '' END
                 -- WAIT_AT_LOW_PRIORITY: without it a queued Sch-M blocks EVERY new
                 -- query on the table while it waits. @LockTimeout does not replace it.
                 + CASE WHEN @Online = 'Y'
                        THEN ', ONLINE = ON'
                           + CASE WHEN @WaitAtLowPriorityMinutes IS NOT NULL
                                  THEN ' (WAIT_AT_LOW_PRIORITY (MAX_DURATION = '
                                     + CAST(@WaitAtLowPriorityMinutes AS nvarchar(max))
                                     + ' MINUTES, ABORT_AFTER_WAIT = ' + @AbortAfterWait + '))'
                                  ELSE '' END
                        ELSE '' END
                 + CASE WHEN @MaxDOP IS NOT NULL THEN ', MAXDOP = ' + CAST(@MaxDOP AS nvarchar(max)) ELSE '' END
                 + ')';

    SET @Comment = 'IndexType: ' + CASE @CurrentIndexType WHEN 0 THEN 'Heap'
                                                          WHEN 1 THEN 'Clustered'
                                                          WHEN 2 THEN 'NonClustered'
                                                          ELSE 'N/A' END
                 + ', Size: ' + CAST(@CurrentPageCount * 8 / 1024 AS nvarchar(max)) + ' MB'
                 + ', DataCompression: ' + @CurrentDecision
                 + ISNULL(', EstimatedSavings: '
                     + CAST(CASE WHEN @CurrentDecision = 'PAGE'
                                 THEN (SELECT SavePagePct FROM #Objects WHERE ID = @ID)
                                 ELSE (SELECT SaveRowPct  FROM #Objects WHERE ID = @ID) END AS nvarchar(max))
                     + '%', '');

    EXECUTE @ReturnCode = dbo.CommandExecute
      @DatabaseContext = @CurrentDatabaseName,
      @Command = @Command,
      @CommandType = @CurrentCommandType,
      @Mode = 2,
      @Comment = @Comment,
      @DatabaseName = @CurrentDatabaseName,
      @SchemaName = @CurrentSchemaName,
      @ObjectName = @CurrentObjectName,
      @ObjectType = 'U',
      @IndexName = @CurrentIndexName,
      @IndexType = @CurrentIndexType,
      @PartitionNumber = @CurrentPartitionNumber,
      @LockMessageSeverity = @LockMessageSeverity,
      @LogToTable = @LogToTable,
      @Execute = @Execute;

    IF @ReturnCode <> 0 SET @Errors = @Errors + 1;

    UPDATE #Objects
       SET Status = CASE WHEN @ReturnCode <> 0 THEN 'ERROR' ELSE 'OK' END,
           Reason  = CASE WHEN @ReturnCode <> 0
                          THEN N'command failed, see the messages above or dbo.CommandLog'
                          ELSE Reason END
     WHERE ID = @ID;

    IF @Delay IS NOT NULL
    BEGIN
      SET @Stmt = 'WAITFOR DELAY ''' + CONVERT(nvarchar(max), DATEADD(SECOND, @Delay, '1900-01-01'), 108) + '''';
      EXECUTE sys.sp_executesql @Stmt;
    END
  END

  ----------------------------------------------------------------------------------------------------
  --// Summary                                                                                    //--
  ----------------------------------------------------------------------------------------------------

  RAISERROR(@EmptyLine, 10, 1) WITH NOWAIT;

  SET @StartMessage = 'Compressed: '  + CAST((SELECT COUNT(*) FROM #Objects WHERE Status = 'OK') AS nvarchar(max))
       + ', skipped: '                + CAST((SELECT COUNT(*) FROM #Objects WHERE Status = 'SKIPPED') AS nvarchar(max))
       + ', errors: '                 + CAST((SELECT COUNT(*) FROM #Objects WHERE Status = 'ERROR') AS nvarchar(max))
       + ', not reached (time limit): ' + CAST((SELECT COUNT(*) FROM #Objects WHERE Status = 'PENDING') AS nvarchar(max))
       + ', duration: ' + CONVERT(nvarchar(max), DATEADD(SECOND, DATEDIFF(SECOND, @StartTime, SYSDATETIME()), '1900-01-01'), 108);
  RAISERROR('%s', 10, 1, @StartMessage) WITH NOWAIT;

  IF @Execute = 'N'
  BEGIN
    RAISERROR('@Execute = N: commands were only printed, the database was not changed.', 10, 1) WITH NOWAIT;
  END

  -- Why an object stays uncompressed after every run is visible here,
  -- not through manual queries against sys.partitions.
  IF EXISTS (SELECT * FROM #Objects WHERE Status IN ('SKIPPED', 'ERROR', 'PENDING'))
  SELECT Status                                   AS [Status],
         DatabaseName                             AS [Database],
         SchemaName + '.' + ObjectName            AS [Table],
         ISNULL(IndexName, '(heap)')              AS [Index],
         PartitionNumber                          AS [Partition],
         CAST(PageCount * 8.0 / 1024 AS decimal(18,2)) AS [MB],
         CAST(100.0 * ISNULL(LobPages, 0) / NULLIF(PageCount, 0) AS decimal(5,2)) AS [LOB_pct],
         SavePagePct                              AS [Saving_PAGE_pct],
         SaveRowPct                               AS [Saving_ROW_pct],
         PctUpdate                                AS [Update_pct],
         Reason                                   AS [Reason]
  FROM #Objects
  WHERE Status IN ('SKIPPED', 'ERROR', 'PENDING')
  ORDER BY PageCount DESC;

  IF @Errors > 0 RETURN 1;
  RETURN 0;
END
GO
