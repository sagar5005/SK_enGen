USE [eBS_Benefit_WYCFG]
GO
/****** Object:  StoredProcedure [AutoMig].[usp_populate_jab_migrationqueue]    Script Date: 9/30/2026 8:44:10 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER   PROCEDURE [AutoMig].[usp_populate_jab_migrationqueue](
   @RunID UNIQUEIDENTIFIER,
   @MigrationBatchID INT
)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY

    -- Load selected LOBs for this run from PopQueueRuns (stored as comma-separated string)
    DECLARE @SelectedLOBs TABLE (LOBName NVARCHAR(100))
    INSERT INTO @SelectedLOBs (LOBName)
    SELECT LTRIM(RTRIM(value))
    FROM AutoMig.PopQueueRuns
    CROSS APPLY STRING_SPLIT(LOBsRequested, ',')
    WHERE RunID = @RunID

    DROP TABLE IF EXISTS #JABMigrationQueueProducts
    CREATE TABLE #JABMigrationQueueProducts (id INT IDENTITY(1,1), product NVARCHAR(500), packagename NVARCHAR(500), Productype VARCHAR(20))

    DECLARE @productname  NVARCHAR(500)
    DECLARE @packagename  NVARCHAR(500)
    DECLARE @producttype  NVARCHAR(500)
    DECLARE @FormInstanceId INT
    DECLARE @i INT = 1

    INSERT INTO #JABMigrationQueueProducts (product, packagename, Productype)

    SELECT DISTINCT Medical_Product, '', 'Medical'
    FROM Autods.WYLG_PackagePortfolioFTMappings
    WHERE ISNULL(Medical_Product, '') <> ''
      AND EXISTS (SELECT 1 FROM @SelectedLOBs WHERE LOBName = 'Medical')

    UNION
    SELECT DISTINCT Rx_Product, '', 'Rx'
    FROM Autods.WYLG_PackagePortfolioFTMappings
    WHERE ISNULL(Rx_Product, '') <> ''
      AND EXISTS (SELECT 1 FROM @SelectedLOBs WHERE LOBName = 'Rx')

    UNION
    SELECT DISTINCT Dental_Product, '', 'Dental'
    FROM Autods.WYLG_PackagePortfolioFTMappings
    WHERE ISNULL(Dental_Product, '') <> ''
      AND EXISTS (SELECT 1 FROM @SelectedLOBs WHERE LOBName = 'Dental')

    UNION
    SELECT DISTINCT Vision_Product, '', 'Vision'
    FROM Autods.WYLG_PackagePortfolioFTMappings
    WHERE ISNULL(Vision_Product, '') <> ''
      AND EXISTS (SELECT 1 FROM @SelectedLOBs WHERE LOBName = 'Vision')

    UNION
    SELECT DISTINCT Package_Name, '', 'Super'
    FROM Autods.WYLG_PackagePortfolioFTMappings
    WHERE ISNULL(Package_Name, '') <> ''
      AND EXISTS (SELECT 1 FROM @SelectedLOBs WHERE LOBName = 'Super Product')

    UNION
    SELECT DISTINCT Service_Product, '', 'Service Product'
    FROM Autods.WYLG_PackagePortfolioFTMappings
    WHERE ISNULL(Service_Product, '') <> ''
      AND EXISTS (SELECT 1 FROM @SelectedLOBs WHERE LOBName = 'Service Products')


    WHILE (@i <= (SELECT MAX(id) FROM #JABMigrationQueueProducts))
    BEGIN
        PRINT @i
        SET @productname = (SELECT product     FROM #JABMigrationQueueProducts WHERE id = @i)
        SET @packagename = (SELECT packagename FROM #JABMigrationQueueProducts WHERE id = @i)
        SET @producttype = (SELECT Productype  FROM #JABMigrationQueueProducts WHERE id = @i)

        IF NOT EXISTS (
            SELECT 1 FROM AutoMig.MigrationQueue
            WHERE FolderName = @productname AND MigrationBatchID = @MigrationBatchID
        )
        BEGIN

            INSERT INTO AutoMig.MigrationQueue (
                 MigrationBatchID
                ,FolderName
                ,FolderVersionNumber
                ,ProductName
                ,ProductType
                ,Region
                ,HIOSID
                ,ProductID
                ,FolderID
                ,FolderVersionID
                ,FormInstanceID
                ,EffectiveDate
                ,IsFoundationTemplate
                ,IsPortfolio
                ,IsPackage
                ,StartTime
                ,EndTime
                ,ProcessStatus1Up
                ,HasError
                ,ErrorDescription
                ,IsActive
                ,CreatedBy
                ,CreatedDate
                ,UpdatedBy
                ,UpdatedDate
                ,FormInstanceName
                ,BeforeMigrationFormData
                ,AfterMigrationFormData
            )
            SELECT
                 @MigrationBatchID
                ,(SELECT name FROM fldr.folder (NOLOCK) WHERE name = @productname AND isportfolio = 1 AND foldertype = CASE WHEN @producttype= 'Super' THEN 5 ELSE 1 END) AS FolderName

               ,(SELECT fv.FolderVersionNumber FROM fldr.folder f (NOLOCK)
                    JOIN fldr.folderversion fv (NOLOCK) ON f.folderid = fv.folderid
                        AND fv.folderversionid = (SELECT MAX(folderversionid) FROM fldr.folderversion (NOLOCK) WHERE folderid = f.folderid)
                    JOIN fldr.forminstance fi (NOLOCK) ON fv.folderversionid = fi.folderversionid AND fi.formdesignid = 2405
                  WHERE f.name = @productname AND f.isportfolio = 1 AND f.foldertype = 1) AS FolderVersionNumber
                ,(SELECT fi.name FROM fldr.folder f (NOLOCK)
                    JOIN fldr.folderversion fv (NOLOCK) ON f.folderid = fv.folderid
                        AND fv.folderversionid = (SELECT MAX(folderversionid) FROM fldr.folderversion WHERE folderid = f.folderid)
                    JOIN fldr.forminstance fi (NOLOCK) ON fv.folderversionid = fi.folderversionid AND fi.formdesignid = 2405
                  WHERE f.name = @productname AND f.isportfolio = 1 AND f.foldertype = CASE WHEN @producttype= 'Super' THEN 5 ELSE 1 END) AS ProductName
                ,CASE WHEN @producttype= 'Super' THEN 'Package' ELSE
                (SELECT lineofbusiness FROM fldr.folder (NOLOCK) WHERE name = @productname AND isportfolio = 1 AND foldertype = 1) END AS ProductType
                ,(SELECT region FROM fldr.folder (NOLOCK) WHERE name = @productname AND isportfolio = 1 AND foldertype = CASE WHEN @producttype= 'Super' THEN 5 ELSE 1 END) AS Region
                ,'' AS HIOSID
                ,(SELECT CASE @producttype
                    WHEN 'Vision'           THEN Vision_PR_ID
                    WHEN 'Rx'               THEN Rx_PR_ID
                    WHEN 'Medical'          THEN Medical_PR_ID
                    WHEN 'Dental'           THEN Dental_PR_ID
                    WHEN 'Super'            THEN Super_PR_ID
                    WHEN 'Service Product' THEN Service_Product_PR_ID
                    ELSE ''
                  END
                  FROM AutoDS.WYLG_PackagePortfolioFTMappings (NOLOCK)
                  WHERE @productname = CASE @producttype
                    WHEN 'Vision'           THEN Vision_Product
                    WHEN 'Rx'               THEN Rx_Product
                    WHEN 'Medical'          THEN Medical_Product
                    WHEN 'Dental'           THEN Dental_Product
                    WHEN 'Super'            THEN Package_Name
                    WHEN 'Service Product' THEN Service_Product
                    ELSE ''
                  END) AS ProductID
                ,(SELECT folderid FROM fldr.folder (NOLOCK) WHERE name = @productname AND isportfolio = 1 AND foldertype = CASE WHEN @producttype= 'Super' THEN 5 ELSE 1 END) AS FolderID
                ,(SELECT MAX(folderversionid) FROM fldr.folderversion (NOLOCK)
                  WHERE folderid = (SELECT folderid FROM fldr.folder (NOLOCK) WHERE name = @productname AND isportfolio = 1 AND foldertype = CASE WHEN @producttype= 'Super' THEN 5 ELSE 1 END)) AS FolderVersionID
                ,(SELECT fi.forminstanceid FROM fldr.folder f (NOLOCK)
                    JOIN fldr.folderversion fv (NOLOCK) ON f.folderid = fv.folderid
                        AND fv.folderversionid = (SELECT MAX(folderversionid) FROM fldr.folderversion (NOLOCK) WHERE folderid = f.folderid)
                    JOIN fldr.forminstance fi (NOLOCK) ON fv.folderversionid = fi.folderversionid AND fi.formdesignid = 2405
                  WHERE f.name = @productname AND f.isportfolio = 1 AND f.foldertype = CASE WHEN @producttype= 'Super' THEN 5 ELSE 1 END) AS FormInstanceID
                ,'2027/01/01' AS EffectiveDate
                ,0  AS IsFoundationTemplate
                ,1  AS IsPortfolio
                ,CASE WHEN @producttype= 'Super' THEN 1 ELSE 0 END  AS IsPackage
                ,NULL AS StartTime
                ,NULL AS EndTime
                ,1  AS ProcessStatus1Up
                ,0  AS HasError
                ,NULL AS ErrorDescription
                ,1  AS IsActive
                ,'JAB' AS CreatedBy
                ,GETDATE() AS CreatedDate
                ,NULL AS UpdatedBy
                ,NULL AS UpdatedDate
                ,@productname AS FormInstanceName
                ,NULL AS BeforeMigrationFormData
                ,NULL AS AfterMigrationFormData

            SET @FormInstanceId = (
                SELECT fi.forminstanceid FROM fldr.folder f
                JOIN fldr.folderversion fv ON f.folderid = fv.folderid
                    AND fv.folderversionid = (SELECT MAX(folderversionid) FROM fldr.folderversion WHERE folderid = f.folderid)
                JOIN fldr.forminstance fi ON fv.folderversionid = fi.folderversionid AND fi.formdesignid = 2405
                WHERE f.name = @productname AND f.isportfolio = 1 AND f.foldertype = CASE WHEN @producttype= 'Super' THEN 5 ELSE 1 END
            )

            -- Only update BeforeMigrationFormData if FormInstanceID exists in FormInstanceDataMap
            IF @FormInstanceId IS NOT NULL
            BEGIN
                UPDATE T
                SET T.BeforeMigrationFormData = dbo.GZip(fd.Formdata)
                FROM AutoMig.MigrationQueue T
                INNER JOIN fldr.FormInstanceDataMap fd ON fd.FormInstanceID = @FormInstanceId
                WHERE T.BeforeMigrationFormData IS NULL
                  AND T.MigrationBatchID = @MigrationBatchID
                  AND T.FolderName = @productname
            END
            ELSE
            BEGIN
                PRINT 'WARNING: No FormInstance found for product: ' + @productname + ' with formdesignid=2405. FormInstanceDataMap update skipped.'
            END

        END
        SET @i = @i + 1
    END


    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage  NVARCHAR(4000)
        DECLARE @ErrorSeverity INT
        DECLARE @ErrorState    INT

        SELECT
             @ErrorMessage  = ERROR_MESSAGE()
            ,@ErrorSeverity = ERROR_SEVERITY()
            ,@ErrorState    = ERROR_STATE()

        PRINT '============================================================'
        PRINT 'ERROR OCCURRED: ' + @ErrorMessage
        PRINT '============================================================'

        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState)
    END CATCH
END
