USE [eBS_enGenWY_CFG]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


/***********************************************************************
Author:  Vaishnavi Rokade
Modified By :
2026-10-26	Fix: component columns (Medical/Rx/Dental/Vision) showing "Not Applicable" in Package Search.
			1) Offer_*_Product flags from the sheet (Yes/No/Y/1/blank) are normalised to 'true'/'false'. Previously they were compared to the literal 'true', so the component JSON merge and the fldr.CompositeFormInstanceMap insert were skipped.
			2) Medical lookup in #instanceList_Medical joined the folder on the PACKAGE folder name; now uses the Medical component folder name (same as Rx/Dental/Vision).
			3) Component merge is skipped (instead of wiping template sections) when the component form data is not found.
			4) CompositeFormInstanceMap source lookups now pick the latest folder version (ORDER BY FolderVersionID DESC), matching the version whose data is merged.
			5) Temp tables used in the per-instance loop are dropped at the start of each iteration.
			6) Section 004 failures are written back to AutoMig.AutoShellRunDetails (RowStatus = CreationFailed).
			7) Removed disabled/dead blocks: 006/007 benefit-info repeater (loop list never matched ProductType = 'Medical', so it never ran) and large commented-out code. Section 008 unchanged.
2026-09-10	BFT Tool  Data source changed from Temp schema staging tables to AutoMig.AutoShellRunDetails JSON
2026-09-12	BFT Tool  Disabled/enabled DML_Trgr_FormInstance + DML_Trgr_FormInstanceDataMap around the per-package form-instance insert loop (matches the other 3 active creation SPs); changed ##FTDetail/##ProductsMetaData from global to session-scoped (#) temp tables
08-04-2026	Vaishnavi R			Changes for HMK shell creation
16-06-2026	Vaishnavi R			Add logic for creating View for ICIS Grid View
21-07-2026	Vaishnavi R			Added logic for creating RX section(RxServices, RxAdditionalServices, RxProgramInformation)
21-07-2026	Vaishnavi R			Added logic for creating Dental section(DentalRiders, DentalRates)
21-07-2026	Vaishnavi R			Added logic for creating Vision section(VisionRates)
Creation Date: 07/31/23
Desc: Generic procedure to create packages from the imported package data

EXEC [AutoMig].[usp_create_shells_packages]  '2DF55E93-88EB-4E7E-A5EE-A3732FD7CAF8'
*************************************************************************/
 ALTER    PROCEDURE [AutoMig].[usp_create_shells_packages](
	@ShellRunID UNIQUEIDENTIFIER
)
AS
BEGIN

	-- =========================================================
	-- All-or-nothing validation gate: if any row for this ShellRunID failed
	-- validation, do not create any shells (including rows that passed) until
	-- the whole batch is valid.
	-- =========================================================
	IF EXISTS (
		SELECT 1 FROM AutoMig.AutoShellRunDetails
		WHERE ShellRunID = @ShellRunID AND RowStatus = 'Invalid'
	)
	BEGIN
		PRINT 'ABORTED: one or more rows for this ShellRunID failed validation. No Package shells were created.'
		RETURN
	END

	-- Stage 3: processing-table setup. #PackageFolderMetaProcessing holds one matched package's
	-- data at a time and is truncated/refilled on each pass through the main WHILE loop below.
	-- Use temp tables to process request record by record
	DROP TABLE IF EXISTS #PackageFolderMetaProcessing
	CREATE TABLE #PackageFolderMetaProcessing (
	    DetailID        BIGINT,
	    ID              INT,
	    Package_Folder_Name          NVARCHAR(500),
	    Package_Name                 NVARCHAR(500),
	    Package_Effective_Date       NVARCHAR(100),
		Market_Segment               NVARCHAR(200),
	    Funding_Arrangement          NVARCHAR(200),
		Offer_Medical_Product        NVARCHAR(10),
	    Offer_Rx_Product             NVARCHAR(10),
	    Offer_Dental_Product         NVARCHAR(10),
	    Offer_Vision_Product         NVARCHAR(10),
	    Offer_Vision_Riders_Product  NVARCHAR(10),
	    State                        NVARCHAR(100),
	    Region                       NVARCHAR(100),

	)

	-- Stage 1: load valid rows from AutoShellRunDetails JSON for each sheet (Package Folder
	-- Meta Data and Package Selection), identified by the "_sheet" key on each JSON row.
	-- Load Sheet 1: Package Folder Meta Data (valid rows only)
	DROP TABLE IF EXISTS #PackageFolderMetaLoaded
	SELECT
	    d.DetailID,
	    ROW_NUMBER() OVER (ORDER BY d.RowNumber) AS ID,
	    JSON_VALUE(d.RowData, '$."Package Folder Name"')           AS ebs_Package_Folder_Name,
	    JSON_VALUE(d.RowData, '$."Package Name"')                   AS Package_Name,
	    JSON_VALUE(d.RowData, '$."Package Effective Date"')         AS Package_Effective_Date,
	    JSON_VALUE(d.RowData, '$."Market Segment"')                 AS Market_Segment,
	    JSON_VALUE(d.RowData, '$."Funding Arrangement"')            AS Funding_Arrangement,
	    JSON_VALUE(d.RowData, '$."Offer Medical Product?"')         AS Offer_Medical_Product,
	    JSON_VALUE(d.RowData, '$."Offer Rx Product?"')              AS Offer_Rx_Product,
	    JSON_VALUE(d.RowData, '$."Offer Dental Product?"')          AS Offer_Dental_Product,
	    JSON_VALUE(d.RowData, '$."Offer Vision Product?"')          AS Offer_Vision_Product,
	    JSON_VALUE(d.RowData, '$."Offer Vision Riders Product?"')   AS Offer_Vision_Riders_Product,
	    JSON_VALUE(d.RowData, '$."State"')                          AS State,
	    JSON_VALUE(d.RowData, '$."Region"')                         AS Region
	INTO #PackageFolderMetaLoaded
	FROM AutoMig.AutoShellRunDetails d
	WHERE d.ShellRunID = @ShellRunID
	  AND JSON_VALUE(d.RowData, '$._sheet') = 'Package Folder Meta Data'
	  AND ISNULL(d.RowStatus, 'Valid') = 'Valid'

	-- Load Sheet 2: Package Selection (valid rows only)
	DROP TABLE IF EXISTS #PackageSelectionLoaded
	SELECT
	    d.DetailID,
	    ROW_NUMBER() OVER (ORDER BY d.RowNumber) AS ID,
	    JSON_VALUE(d.RowData, '$."Package Folder Name"')                    AS ebs_Package_Folder_Name,
	    JSON_VALUE(d.RowData, '$."Package Name"')                            AS eBS_PACKAGE_NAME,
	    JSON_VALUE(d.RowData, '$."Package Effective Date"')                  AS Package_Effective_Date,
	    JSON_VALUE(d.RowData, '$."Package Expiration Date"')                 AS Package_Expiration_Date,
	    JSON_VALUE(d.RowData, '$."Enable QHP?"')   AS Enable_QHP,
	    JSON_VALUE(d.RowData, '$."Are the Medical and Drug Deductible Integrated?"') AS Med_Drug_Ded_Integrated,
	    JSON_VALUE(d.RowData, '$."Are the Medical and Drug OOPM Integrated?"')       AS Med_Drug_OOPM_Integrated,
	    JSON_VALUE(d.RowData, '$."Medical Product Folder Name"')             AS eBS_Medical_COMPONENT,
	    JSON_VALUE(d.RowData, '$."Medical Product Name"')                    AS Medical_Product_Name,
	    JSON_VALUE(d.RowData, '$."Medical Version"')                         AS Medical_Version,
	    JSON_VALUE(d.RowData, '$."Medical Effective Date"')                  AS Medical_Effective_Date,
	    JSON_VALUE(d.RowData, '$."Rx Product Folder Name"')                  AS eBS_Rx_COMPONENT,
	    JSON_VALUE(d.RowData, '$."Rx Product Name"')                         AS Rx_Product_Name,
	    JSON_VALUE(d.RowData, '$."Rx Version"')                              AS Rx_Version,
	    JSON_VALUE(d.RowData, '$."Rx Effective Date"')                       AS Rx_Effective_Date,
	    JSON_VALUE(d.RowData, '$."Dental Product Folder Name"')              AS eBS_Dental_COMPONENT,
	    JSON_VALUE(d.RowData, '$."Dental Product Name"')                     AS Dental_Product_Name,
	    JSON_VALUE(d.RowData, '$."Dental Version"')                          AS Dental_Version,
	    JSON_VALUE(d.RowData, '$."Dental Effective Date"')                   AS Dental_Effective_Date,
	    JSON_VALUE(d.RowData, '$."Vision Product Folder Name"')              AS eBS_Vision_COMPONENT,
	    JSON_VALUE(d.RowData, '$."Vision Product Name"')                     AS Vision_Product_Name,
	    JSON_VALUE(d.RowData, '$."Vision Version"')                          AS Vision_Version,
	    JSON_VALUE(d.RowData, '$."Vision Effective Date"')                   AS Vision_Effective_Date,
	    JSON_VALUE(d.RowData, '$."Hearing Product Folder Name"')             AS eBS_Hearing_COMPONENT,
	    JSON_VALUE(d.RowData, '$."Hearing Product Name"')                    AS Hearing_Product_Name,
	    JSON_VALUE(d.RowData, '$."Hearing Version"')                          AS Hearing_Version,
	    JSON_VALUE(d.RowData, '$."Hearing Effective Date"')                   AS Hearing_Effective_Date,
	    JSON_VALUE(d.RowData, '$."Vision Riders Product Folder Name"')       AS eBS_Vision_Riders_COMPONENT,
	    JSON_VALUE(d.RowData, '$."Vision Riders Product Name"')              AS Vision_Riders_Product_Name,
	    JSON_VALUE(d.RowData, '$."Vision Riders Version"')                   AS Vision_Riders_Version,
	    JSON_VALUE(d.RowData, '$."Vision Riders Effective Date"')            AS Vision_Riders_Effective_Date,
	    JSON_VALUE(d.RowData, '$."Offer Medical Product?"')                  AS Offer_Medical_Product,
	    JSON_VALUE(d.RowData, '$."Offer Rx Product?"')                       AS Offer_Rx_Product,
	    JSON_VALUE(d.RowData, '$."Offer Dental Product?"')                   AS Offer_Dental_Product,
	    JSON_VALUE(d.RowData, '$."Offer Vision Product?"')                   AS Offer_Vision_Product,
	    JSON_VALUE(d.RowData, '$."Offer Vision Riders Product?"')            AS Offer_Vision_Riders_Product,
	    JSON_VALUE(d.RowData, '$."Market Segment"')                          AS Market_Segment,
	    JSON_VALUE(d.RowData, '$."State"')                                   AS State,
	    JSON_VALUE(d.RowData, '$."Region"')                                  AS Region
	INTO #PackageSelectionLoaded
	FROM AutoMig.AutoShellRunDetails d
	WHERE d.ShellRunID = @ShellRunID
	  AND JSON_VALUE(d.RowData, '$._sheet') = 'Package Selection'
	  AND ISNULL(d.RowStatus, 'Valid') = 'Valid'

	-- Stage 2: keep only package pairs present and valid in both sheets.
	-- Join the two sheets (only packages where BOTH sheets are valid)

	select  DISTINCT a.*
	into #PackageFolderMetaMatched
	from #PackageFolderMetaLoaded a
	join #PackageSelectionLoaded b
	on a.Package_Name = b.eBS_PACKAGE_NAME

	select  b.* into #PackageSelectionMatched
	from #PackageFolderMetaLoaded a
	join #PackageSelectionLoaded b
	on a.Package_Name = b.eBS_PACKAGE_NAME

	DROP TABLE IF EXISTS #PackageFolderMetaLoaded
	DROP TABLE IF EXISTS #PackageSelectionLoaded

	-- Main processing loop: while unprocessed matched packages remain, pull one at a time into
	-- the Stage 3 processing tables and run the Facets/PBT folder, plan, and JSON creation logic below.
	WHILE ((SELECT COUNT(1) FROM #PackageFolderMetaMatched) > 0)
	BEGIN
		TRUNCATE TABLE #PackageFolderMetaProcessing
		DROP TABLE IF EXISTS #PackageSelectionProcessing

		-- Delete record from staging table and load deleted one into temp table which is used for further processing
		DELETE TOP (1) FROM #PackageFolderMetaMatched
		OUTPUT DELETED.DetailID,  DELETED.ID,
    DELETED.eBS_Package_Folder_Name,  DELETED.Package_Name,  DELETED.Package_Effective_Date,
    DELETED.Market_Segment, DELETED.Funding_Arrangement,
    DELETED.Offer_Medical_Product,DELETED.Offer_Rx_Product,DELETED.Offer_Dental_Product,
    DELETED.Offer_Vision_Product,DELETED.Offer_Vision_Riders_Product, DELETED.State,
    DELETED.Region
	INTO #PackageFolderMetaProcessing

		SELECT TOP 1 x.*
		INTO #PackageSelectionProcessing
		FROM #PackageSelectionMatched x
			JOIN #PackageFolderMetaProcessing y ON x.ebs_Package_Name = y.Package_Name

	-------------*************************************002.CreateFolderListTable_Package_NC : START **********************************************--------------------
		-- Build the list of foundation-template folders/plans these packages need created against.

		IF (NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'Migration'))
		BEGIN
			EXEC ('CREATE SCHEMA Migration');
		END

		IF (NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'Temp'))
		BEGIN
			EXEC ('CREATE SCHEMA Temp');
		END

		DROP TABLE IF EXISTS #FTDetail;


		;with cte as
		(
		SELECT DISTINCT 'Package' ProductType,'' eBS_Medical_Foundation_Template ,ebs_Package_Folder_Name,ebs_Package_Name
		FROM #PackageSelectionProcessing (NOLOCK)
		)

		SELECT DISTINCT C.*,F.Name [FoundationFolderName] ,F.FolderID,F.StateName  StateName,F.Region,F.MarketSegmentID,F.FundingArrangement,F.LineofBusiness,isnull(V.EffectiveDate,getdate()) AS EffectiveDate
		INTO #FTDetail
		FROM cte C
		INNER JOIN Fldr.FormInstance I (NOLOCK) ON C.ebs_Package_Name = I.Name AND I.FormDesignID = 2405
		INNER JOIN fldr.FolderVersion V (NOLOCK) ON I.FolderVersionID = V.FolderVersionID
		INNER JOIN fldr.Folder F (NOLOCK) ON V.FolderID = F.FolderID
		and F.IsPortfolio = 1 and F.IsFoundation = 1
		and V.folderversionid = (select max(folderversionid) from fldr.folderversion where FolderID=F.FolderID)
		ORDER BY F.Name,C.ebs_Package_Name

		DROP TABLE IF EXISTS Migration.packageListToBeMigrate_SG;

		CREATE TABLE Migration.packageListToBeMigrate_SG (
			Id						INT IDENTITY(1,1),
			ProductType             VARCHAR(100),
			FolderName              NVARCHAR(MAX),
			FolderType              INT,
			StateName               NVARCHAR(MAX),
			InstanceName			NVARCHAR(MAX),
			LineofBusiness		    NVARCHAR(MAX),
			FundingArrangement	    NVARCHAR(MAX),
			MarketSegmentId			NVARCHAR(MAX),
			Region				    NVARCHAR(MAX),
			BatchId					INT NULL,
			Comment					NVARCHAR(MAX) NULL,
			EffectiveDate			DateTIME
		)


		INSERT INTO Migration.packageListToBeMigrate_SG(FolderType,ProductType,FolderName,InstanceName)
		SELECT DISTINCT 5,'Package',ebs_Package_Folder_Name,ebs_Package_Name
		FROM #PackageSelectionProcessing (NOLOCK)


		DROP TABLE IF EXISTS #ProductsMetaData;

		CREATE TABLE #ProductsMetaData(
		  ProductType				nvarchar(max)
		,[Workflow Category]		nvarchar(max)
		,[Folder Mode]				nvarchar(max)
		,[Line of Business]			nvarchar(max)
		,[Product Name]				nvarchar(max)
		,Package_Name				nvarchar(max)
		,Package_Effective_Date	    datetime
		,Package_Expiration_Date	datetime
		,Market_Segment			    nvarchar(max)
		,[Jurisdiction]				nvarchar(max)
		,[Region]					nvarchar(max)
		,[Enable QHP?]				nvarchar(max)
		,Funding_Arrangement		nvarchar(max)
		,Offer_Medical_Product	nvarchar(max)
		,Offer_Rx_Product		nvarchar(max)
		,Offer_Dental_Product	nvarchar(max)
		,Offer_Vision_Product	nvarchar(max))


		Insert into #ProductsMetaData(ProductType
				,[Workflow Category]
				,[Folder Mode]
				,[Line of Business]
				,[Product Name]
				,Package_Name
				,Package_Effective_Date
				,Market_Segment
				,[Jurisdiction]
				,[Region]
				,Funding_Arrangement
				,Offer_Medical_Product
				,Offer_Rx_Product
				,Offer_Dental_Product
				,Offer_Vision_Product	)
		Select distinct 'Package'
				,'Package Build' --Default
				,'Prod'					-- FolderMode defaulted to Prod
				,''
				,Package_Folder_Name
				,Package_Name
				,ISNULL(Package_Effective_Date,GETDATE())
				,Market_Segment
				,[State]
				,[Region]
				,Funding_Arrangement
				,Offer_Medical_Product
				,Offer_Rx_Product
				,Offer_Dental_Product
				,Offer_Vision_Product FROM #PackageFolderMetaProcessing Data(NOLOCK)


		UPDATE T SET T.Statename = MF.[Jurisdiction],
		T.FundingArrangement = MF.[Funding_Arrangement],
		T.Region = MF.Region,
		T.LineofBusiness = ISNULL(MF.[Line of Business],''),
		T.MarketSegmentId = ISNULL(MF.[Market_Segment],''),
		T.EffectiveDate= ISNULL(MF.[Package_Effective_Date],GETDATE())
		FROM Migration.packageListToBeMigrate_SG T
		LEFT JOIN #ProductsMetaData MF ON T.FolderName = MF.[Product Name] and T.ProductType = MF.ProductType

		---BATCH lOGIC
		SET NOCOUNT ON;


		DECLARE @i INT = 1
		DECLARE @TotalCount INT = 0;
		DECLARE @BatchId INT = 1;
		DECLARE @PerBatchRecord INT = 0;
		DECLARE @Divisior INT = 2; --3
		DECLARE @SQL NVARCHAR(MAX) = '';
		DECLARE @SQL_LogTableName NVARCHAR(MAX)='';

		SELECT @TotalCount = COUNT(1) FROM Migration.packageListToBeMigrate_SG (NOLOCK)
		SET @PerBatchRecord = @TotalCount/@Divisior;

		WHILE (@BatchId <= @Divisior)
		BEGIN
			SET @SQL_LogTableName = '';
			SET @SQL_LogTableName = 'Log.MigrationActivityLog_'  + CAST(@BatchId as varchar(100));

			SET @SQL = ''
			SET @SQL = 'DROP TABLE IF EXISTS ' + @SQL_LogTableName;
			EXECUTE sp_executesql @SQL;

			SET @SQL = ''
			SET @SQL = 'CREATE TABLE ' + @SQL_LogTableName + ' ( Id INT IDENTITY(1,1), BatchId INT NULL, MigrationId INT NULL, FolderName NVARCHAR(MAX), ProductName NVARCHAR(MAX), ActivityDetail NVARCHAR(MAX) ) '
			EXECUTE sp_executesql @SQL;

			SET @SQL = '';
			SET @SQL = ' ;WITH Cte AS (
					SELECT DISTINCT Id,ProductType,FolderName,FolderType,BatchId,ROW_NUMBER() OVER(Order By Id) AS RN
					FROM Migration.packageListToBeMigrate_SG S (NOLOCK)
				)
				UPDATE O SET O.BatchId = '+ CAST(@BatchId as varchar(10))+'
				FROM Cte C
				INNER JOIN Migration.packageListToBeMigrate_SG O ON C.Id = O.Id
				WHERE RN BETWEEN ' + CAST(@i as varchar(10))+ ' AND ' + CAST(@i+@PerBatchRecord as varchar(100));

			EXECUTE sp_executesql @SQL;

			SET @BatchId = @BatchId + 1;
			SET @i = @i + @PerBatchRecord + 1;
		END

		--END BATCH LOGIC HERE

		DROP TABLE IF EXISTS Migration.packagePlansToBeMigrated;

		CREATE TABLE Migration.packagePlansToBeMigrated (Id INT IDENTITY(1,1), PackageName NVARCHAR(MAX), FolderName NVARCHAR(MAX), FTName NVARCHAR(MAX), ProductType NVARCHAR(100), FolderType NVARCHAR(10));

		INSERT INTO Migration.packagePlansToBeMigrated(FolderType,ProductType,FolderName,PackageName,FTName)

		SELECT DISTINCT 5,'Package' ,Package_Folder_Name,Package_Name,''
		FROM #PackageFolderMetaProcessing(NOLOCK) --package

		DROP TABLE IF EXISTS Migration.WorkFlowStateDetails;

		SELECT DISTINCT G.FolderVersionGroupName,CAT.FolderVersionCategoryName ,ST.WFStateName,S.WorkFlowVersionStateID,S.[Sequence]
		INTO Migration.WorkFlowStateDetails
		FROM WF.WorkFlowVersionState S (NOLOCK)
		inner join wf.[State] ST (NOLOCK)ON S.WFStateID = ST.WFStateID
		inner join WF.WorkFlowCategoryMapping CM (NOLOCK)ON S.WorkFlowVersionID = CM.WorkFlowVersionID
		inner join Fldr.FolderVersionCategory CAT (NOLOCK)ON CM.FolderVersionCategoryID = CAT.FolderVersionCategoryID
		inner join Fldr.FolderVersionGroup G (NOLOCK) ON CAT.FolderVersionGroupID = G.FolderVersionGroupID
		WHERE 1 = 1
		ORDER BY FolderVersionGroupName,FolderVersionCategoryName,S.[Sequence]

	-------------************************************* 002.CreateFolderListTable_Package_NC : Finish **********************************************--------------------


	-------------************************************* 003.CreatePackageFolderAndPlans_WIth All_views : Start **********************************************--------------------
		-- Create the package folder and folder version, then (per plan/product, see loop below) one
		-- form instance seeded with the default JSON template for each plan in the package.


		DECLARE @FoldeAndFTList AS TABLE
		(
			Id	int IDENTITY(1,1),
			ProductType	varchar(MAX),
			FolderName	nvarchar(MAX),
			FolderType	nvarchar(MAX),
			StateName nvarchar(100),
			LineofBusiness	nvarchar(max),
			FundingArrangement Nvarchar(100),
			MarketSegmentID   nvarchar(max),
			Region nvarchar(100),
			IsProcessed	bit DEFAULT 0,
			Effectivedate date
		)

		INSERT INTO @FoldeAndFTList (ProductType,FolderName,FolderType,StateName,LineofBusiness,FundingArrangement,Region,MarketSegmentID,Effectivedate)
		SELECT DISTINCT ProductType,FolderName,FolderType
		,StateName,LineofBusiness,FundingArrangement,Region,MarketSegmentId,EffectiveDate
		FROM Migration.packageListToBeMigrate_SG (NOLOCK)


		DECLARE @Date					                            DATETIME				= GETDATE()
		DECLARE @Id						                            INT;
		DECLARE @FolderName				                            NVARCHAR(MAX);
		DECLARE @FTName					                            NVARCHAR(MAX);
		DECLARE @WFStateId				                            NVARCHAR(MAX);
		DECLARE @UserID					                            INT
		DECLARE @IsPortfolio			                            INT						= 1
		DECLARE @FormID					                            INT
		DECLARE @FormID_Medical 	                                INT
		DECLARE @FormID_Rx			                                INT
		DECLARE @FormID_Vision			                            INT
		DECLARE @FormID_Dental			                            INT
		DECLARE @FormID_Package			                            INT
		DECLARE @FormID_SOB	                                        INT
		DECLARE @FormID_SBC	                                        INT
		DECLARE @FormID_Plan_and_Benefit_Template_View	            INT
		DECLARE @FormID_SBC_Calculator_View	                        INT
		DECLARE @FormDesignVersionID	                            INT
		DECLARE @FormDesignVersionID_Medical	                    INT
		DECLARE @FormDesignVersionID_Rx	                            INT
		DECLARE @FormDesignVersionID_Vision			              	INT
		DECLARE @FormDesignVersionID_Dental			              	INT
		DECLARE @FormDesignVersionID_Package			            INT
		DECLARE @FormDesignVersionID_SOB	                        INT
		DECLARE @FormDesignVersionID_SBC	                        INT
		DECLARE @FormDesignVersionID_Plan_and_Benefit_Template_View	INT
		DECLARE @FormDesignVersionID_SBC_Calculator_View	        INT
		DECLARE @AddedBy				                            VARCHAR(10)				= 'SuperUser'
		DECLARE @FolderID				                            INT
		DECLARE @Folder					                            NVARCHAR(MAX) = @FolderName
		DECLARE @TenantID				                            INT = 1
		DECLARE @RowCount				                            INT
		DECLARE @FolderVersionId		                            INT
		DECLARE @FormInstanceId			                            INT
		DECLARE @FormInstanceId_Business							INT
		DECLARE @FormDesgin				                            NVARCHAR(MAX)
		DECLARE @PlanName				                            NVARCHAR(MAX)
		DECLARE @ProductType				                        NVARCHAR(100)
		DECLARE @ProductTypeId				                        INT
		DECLARE @FormData				                            NVARCHAR(MAX)
		DECLARE @ApprovalStatusId		                            INT
		DECLARE @FOlderType				                            NVARCHAR(100)
		DECLARE @Comment											NVARCHAR(MAX);
		DECLARE @IsPackage											BIT;
		DECLARE @FolderversionNumber								NVARCHAR(100) = '2027_0.01';
		DECLARE @FOlderVersionCategory								NVARCHAR(100) = 'Package Build'
		DECLARE @FOlderVersionCategoryId								INT
		DECLARE @Statename											NVARCHAR(MAX)
		DECLARE @LineofBusiness										NVARCHAR(MAX)
		DECLARE @FundingArrangement									NVARCHAR(MAX)
		DECLARE @Region												NVARCHAR(MAX)
		DECLARE @MarketSegmentID                                    NVARCHAR(MAX)
		DECLARE @EffDate					                        DATETIME='1/1/2027'   ---Added By VR
		DECLARE @ProductBuildID										int;


		SELECT @ApprovalStatusId = ApprovalStatusID from Fldr.ApprovalStatusType  where ApprovalStatus = 'Not Approved';
		SELECT @FOlderVersionCategoryId = FolderVersionCategoryID from Fldr.FolderVersionCategory Where FolderVersionCategoryName= @FOlderVersionCategory
		SELECT @WFStateId = WorkFlowVersionStateID FROM  Migration.WorkFlowStateDetails WHERE FolderVersionCategoryName = @FOlderVersionCategory and [Sequence] = 1;

		SELECT @UserID = USERID FROM SEC.[User] (NOLOCK) WHERE UserName = @AddedBy;

		SELECT @FormId = FormID FROM UI.FormDesign D (NOLOCK) WHERE FormName = 'CommercialMedicalAnchor'
		SELECT @FormDesignVersionID = MAX(FormDesignVersionID) FROM UI.FormDesignVersion V (NOLOCK) WHERE FormDesignID = @FormID;

		DECLARE @FormInstanceMapTypeId INT;
		SELECT @FormInstanceMapTypeId = FormInstanceMapTypeID FROM Fldr.FormInstanceMapType where FormInstanceMapType  = 'Package';

		SELECT @FormID_Medical 	 = FormID FROM UI.FormDesign D (NOLOCK) WHERE FormName = 'MedicalProducts'
		SELECT @FormDesignVersionID_Medical = MAX(FormDesignVersionID) FROM UI.FormDesignVersion V (NOLOCK) WHERE FormDesignID =@FormID_Medical ;

		SELECT @FormID_Rx = FormID FROM UI.FormDesign D (NOLOCK) WHERE FormName = 'RxProducts'
		SELECT @FormDesignVersionID_Rx = MAX(FormDesignVersionID) FROM UI.FormDesignVersion V (NOLOCK) WHERE FormDesignID = @FormID_Rx;

		SELECT @FormID_Vision = FormID FROM UI.FormDesign D (NOLOCK) WHERE FormName = 'VisionProducts'
		SELECT @FormDesignVersionID_Vision = MAX(FormDesignVersionID) FROM UI.FormDesignVersion V (NOLOCK) WHERE FormDesignID = @FormID_Vision;

		SELECT @FormID_Dental = FormID FROM UI.FormDesign D (NOLOCK) WHERE FormName = 'DentalProduct'
		SELECT @FormDesignVersionID_Dental = MAX(FormDesignVersionID) FROM UI.FormDesignVersion V (NOLOCK) WHERE FormDesignID = @FormID_Dental;

		SELECT @FormID_Package = FormID FROM UI.FormDesign D (NOLOCK) WHERE FormName = 'AllProductsandPackages'
		SELECT @FormDesignVersionID_Package = MAX(FormDesignVersionID) FROM UI.FormDesignVersion V (NOLOCK) WHERE FormDesignID =@FormID_Package;

		SELECT @FormID_SOB = FormID FROM UI.FormDesign D (NOLOCK) WHERE FormName = 'CommercialCOBDesign'
		SELECT @FormDesignVersionID_SOB = MAX(FormDesignVersionID) FROM UI.FormDesignVersion V (NOLOCK) WHERE FormDesignID =@FormID_SOB;

		SELECT @FormID_SBC = FormID FROM UI.FormDesign D (NOLOCK) WHERE FormName = 'SBCDesign'
		SELECT @FormDesignVersionID_SBC = MAX(FormDesignVersionID) FROM UI.FormDesignVersion V (NOLOCK) WHERE FormDesignID =@FormID_SBC;

		SELECT @FormID_Plan_and_Benefit_Template_View = FormID FROM UI.FormDesign D (NOLOCK) WHERE FormName = 'PlansandBenefitTemplate'
		SELECT @FormDesignVersionID_Plan_and_Benefit_Template_View = MAX(FormDesignVersionID) FROM UI.FormDesignVersion V (NOLOCK) WHERE FormDesignID =@FormID_Plan_and_Benefit_Template_View;

		SELECT @FormID_SBC_Calculator_View = FormID FROM UI.FormDesign D (NOLOCK) WHERE FormName = 'SBCCalculatorView'
		SELECT @FormDesignVersionID_SBC_Calculator_View = MAX(FormDesignVersionID) FROM UI.FormDesignVersion V (NOLOCK) WHERE FormDesignID =@FormID_SBC_Calculator_View;

		-------ICIS grid view add-----------
		declare @FormID_ICIS_Grid_View int;
		Declare @FormDesignVersionID_ICIS_Grid_View int;

		SELECT @FormID_ICIS_Grid_View = FormID FROM UI.FormDesign D (NOLOCK) WHERE FormName = 'ICISGridView'
		SELECT @FormDesignVersionID_ICIS_Grid_View = MAX(FormDesignVersionID) FROM UI.FormDesignVersion V (NOLOCK) WHERE FormDesignID =@FormID_ICIS_Grid_View;

		WHILE EXISTS (SELECT 1 FROM @FoldeAndFTList WHERE IsProcessed = 0)
		BEGIN
			SET @Id					= NULL;
			SET @FolderName			= NULL;
			SET @FTName				= NULL;
			SET @FolderID			= NULL;
			SET @Folder				= NULL;
			SET @RowCount			= NULL;
			SET @FolderVersionId	= NULL;
			SET @FormInstanceId		= NULL;
			SET @FormInstanceId_Business = NULL;
			SET @FormDesgin			= NULL;
			SET @PlanName			= NULL;
			SET @FormData			= NULL;
			SET @IsPackage			= NULL;
			SET @Statename			= NULL;
			SET @LineofBusiness		= NULL;
			SET @FundingArrangement	= NULL;
			SET @Region				= NULL;
			SET @MarketSegmentID    = NULL;
			SET @EffDate			= NULL;
			SET @ProductBuildID		= NULL;

			SELECT TOP 1 @Id = Id,@FolderName = FolderName,@FOlderType = FolderType, @ProductType = ProductType, @Statename = Statename,
			@LineofBusiness = LineofBusiness,@FundingArrangement = FundingArrangement,@Region = Region,@MarketSegmentID=MarketSegmentID,@EffDate=EffectiveDate
			FROM @FoldeAndFTList
			WHERE IsProcessed = 0;
			SET @Folder = @FolderName ;

			BEGIN TRANSACTION
			BEGIN TRY
				/*Folder START*/
				INSERT INTO Fldr.Folder (IsPortfolio, Name, MarketSegmentID, PrimaryContent, PrimaryContentID, TenantID,
											AddedDate, AddedBy,UpdatedDate, UpdatedBy, ParentFolderId,
											FormDesignGroupId,IsPackage,IsFoundation,StateName,LineofBusiness,
											FundingArrangement,Region,FolderType,FolderModeId )
				SELECT @IsPortfolio
					, @Folder Name
					, @MarketSegmentID
					, 'Migration' PrimaryContent
					, @UserID PrimaryContentID
					, @TenantID TenantID
					, @Date AS  AddedDate
					, @AddedBy AddedBy
					, NULL UpdatedDate
					, NULL UpdatedBy
					, NULL ParentFolderId
					, NULL FormDesignGroupId
					, 1
					, 0
					,@StateName
					,@LineOfBusiness
					,@FundingArrangement
					,@Region
					,@FolderType
					,2
				SET @FolderID = SCOPE_IDENTITY();

				/*Folder Version START*/
				select @ProductBuildID =FolderVersionCategoryID from Fldr.FolderVersionCategory where FolderVersionCategoryName IN('Package Build');

				INSERT INTO Fldr.Folderversion (FolderID, EffectiveDate, WFStateID, FolderVersionNumber, VersionTypeID, IsActive, TenantID, AddedDate
											, AddedBy, Comments, FolderVersionStateID, FolderVersionBatchID, ConsortiumID, CategoryID, CatID)
				SELECT DISTINCT @FolderID AS FolderId
					, @EffDate AS EffectiveDate
					, @WFStateId AS WFStateID
					, @FolderversionNumber AS FolderVersionNumber
					, 1 AS VersionTypeID
					, 1 AS IsActive
					, @TenantID AS TenantID
					, @Date AS AddedDate
					, @AddedBy AS AddedBy
					, @AddedBy + ' created Initial minor version ' + @FolderversionNumber + ' during migration.' AS Comment
					, 1 AS FolderversionStateID
					, NULL AS FolderVersionBatchID
					, NULL AS ConsortiumId
					, @ProductBuildID AS CategoryID
					, '' AS CatID

				SET @FolderVersionId = SCOPE_IDENTITY()

				INSERT INTO Fldr.FolderVersionWorkFlowState(TenantID,IsActive,AddedBy,AddedDate,FolderVersionID,WFStateID,ApprovalStatusID,Comments,UserID)
				SELECT @TenantID,1,@AddedBy,@Date,@FolderVersionId,@WFStateId,@ApprovalStatusId,NULL,@UserID;

				DECLARE @PlanList AS TABLE (
					Id INT IDENTITY(1,1), PlanName NVARCHAR(MAX), FTName NVARCHAR(MAX),ProductType NVARCHAR(100)
				)

				INSERT INTO @PlanList(PlanName,FTName,ProductType)
				SELECT DISTINCT foldername,FTName,ProductType FROM Migration.packagePlansToBeMigrated WHere FolderName = @FolderName AND FOlderTYpe = @FOlderType Order by foldername;

				/*Form Instance START*/
				-- Create one folder + form instance per plan/product in this package (Package, Medical, Rx,
				-- Dental, Vision, SOB, SBC, Plan and Benefit Template View, ICIS Grid View, SBC Calculator View),
				-- seeding each new instance with its default JSON template.
				-- Disabled for the whole batch of inserts below (not once per plan) so this matches the
				-- other 3 active creation SPs, which all suppress these same shared triggers while writing
				-- to Fldr.FormInstance / FormInstanceDataMap.
				ALTER TABLE [Fldr].[FormInstance] DISABLE TRIGGER [DML_Trgr_FormInstance]
				ALTER TABLE [Fldr].[FormInstanceDataMap] DISABLE TRIGGER [DML_Trgr_FormInstanceDataMap]

				WHILE EXISTS(SELECT 1 FROM @PlanList)
				BEGIN

				-------------------------------------------------------------------------------------------------------------
				--bussiness
					SET @PlanName					= NULL;
					SET @FTName						= NULL;
					SET @ProductType				= NULL;
					SET @FormInstanceId				= NULL;
					SET @FormInstanceId_Business	= NULL;
					SET @ProductTypeId				= NULL;

					SELECT TOP 1 @PlanName = PlanName, @FTName = FTName,@ProductType = ProductType FROM @PlanList;
					SELECT @ProductTypeId = FormInstanceMapTypeID FROM Fldr.FormInstanceMapType M (NOLOCK) WHERE FormInstanceMapType = @ProductType;

					SET @IsPackage = CASE WHEN @ProductType = 'Package' THEN 1 ELSE 0 END
					SET @FormData= '{"Summary":{"ProductType":"Package","FoundationTemplateInformation":{"IsFoundationtemplate":"false","Module":"PACKAGE","ContactInfo":""},"SummarySection":{}},"PackageSelection":{"PackageID":"","PackageName":"","PackageEffectiveDate":"","PackageExpirationDate":"","MarketSegment":"","FundingArrangement":"","State":"","Region":"","EnableQHP":"","BundledProducts":{"OfferMedicalProduct":true,"OfferRxProduct":true,"OfferDentalProduct":true,"OfferVisionProduct":true,"OfferHearingProduct":false},"IntegratedQuestions":{"AretheMedicalandDrugDeductibleIntegrated":"False","AretheMedicalandDrugOOPMIntegrated":"False","AretheMedicalandDrugTMOOPIntegrated":"","AretheMedicalandDentalDeductibleIntegrated":"","AretheMedicalandDentalOOPMIntegrated":"","AretheMedicalandVisionDeductibleIntegrated":"","AretheMedicalandVisionOOPMIntegrated":""},"MedicalProductSelection":{"SelectMedicalProduct":"","ProductID":"","FolderName":"","Version":"","EffectiveDate":""},"RxProductSelection":{"SelectRxProduct":"","ProductID":"","FolderName":"","Version":"","EffectiveDate":""},"DentalProductSelection":{"SelectDentalProduct":"","ProductID":"","FolderName":"","Version":"","EffectiveDate":""},"VisionProductSelection":{"SelectVisionProduct":"","ProductID":"","FolderName":"","FolderVersion":"","EffectiveDate":""},"HearingProductSelection":{"SelectHearingProduct":"","FolderName":"","Version":"","EffectiveDate":""}},"ProductRules":{"PlanInformation":{"BasePlanTemplate":"","PackageNameFacetsName":"","LineofBusiness":"","FundingArrangement":"","MarketSegment":"","TypeofPlan":"","ProductType":"","ProductID":"Blank","PediatricDentalPDPDId":"","PediatricVisionPDPDId":"","Plantobesoldinwhichstate":"","Region":"","MedicalOptionNumber":"","PlanEffectiveDate":"","PlanRenewalDate":"","AVValues":"","DeductibleOptions":"","OOPMOptions":"Yes OOPM","FiledLegalEntityinnetworkentity":"","FiledLegalEntityoutofnetworkentity":"","OutofNetworkBenefits":"","PriorAuthorizationsetup":"","ReferralsRequired":"","PCPSelectionRequired":"","ClassDescription":"","MedicalPlanID":"","ClassCode":"","AlphaPrefix":"","SMARTSPRODCODE":"","SMARTSProgram":"","NWST":"","BSBS":"","IncludesPediatricVision":"","IncludesPediatricDental":"","PlanYearorCalendarYear":"","PlanYearMonth":"","ProductOffering":"","CDHType":"","CDHIndicator":"","SpendingAccount":"","FundType":"","DeductibleCarryover":"","ServiceGroup":"","MHPProductIndicator":"","ExchangeStandardPlan":"","PackageName":"","VirtualConnectBenefits":"","IncludesElectiveAbortion":"","CongressionalPlan":""},"PlanDetails":{"IsthisaGrandfatheredPlan":"","IsthisplansubjecttoERISA":"False","IsthisaCOBRAPlan":"False","DoesthisplanmeetMinimumValueStandards":"","IsthisaCostSharereductionplanCDOnly":"","VBID":"","IsthisaChurchPlan":"False","DoesthisplanprovideMinimumEssentialCoverage":"","SelectDeductibleRider":"","OnExchangeNativeAmericanplanvariationsneededCDonly":"","DoesthisplanmeetstheMinimumCreditableCoveragestandards":""},"CustomerServiceInformation":{"CustomerServiceNumber":"","CustomerServiceWebsite":"","FormID":"","Blank":""}},"Network":{"NetworkTierList":[{"NetworkTier":"","NetworkName":""}],"CoverageLevelList":[{"CoverageName":"","CoverageDisplayName":""}],"ProviderNetworkMap":{"ProviderNetworkList":[{"NetworkTier":"","ServiceArea":"","ProviderNetworkName":""}]}},"GeneralCostShare":{"FoundationTemplatesDecisions":{"DoestheFoundationTemplatehaveDifferentGuardrailsforEmbeddedandNonEmbed":"","DoesthisplanincludeaMiscellaneousDeductible":""},"CoinsuranceGuardrail":{"GuardrailsCoinsuranceList":[{"NetworkName":"","NetworkTier":"","CoinsuranceAmountLow":"","CoinsuranceAmountHigh":"","CoinsuranceAmountIncrement":"","AllowableCoinsuranceAmount":"","StandardCoinsuranceAmount":""}]},"Coinsurance":{"CoinsuranceList":[{"NetworkTier":"","NetworkName":"","CoinsuranceAmount":"","EnableUpdate":"False","MandateType":""}]},"DeductibleGuardrail":{"GuardrailsDeductibleList":[{"CoverageName":"","NetworkTier":"","NetworkName":"","EmbeddedorNonEmbedded":"","DeductibleAmountLow":"","DeductibleAmountHigh":"","DeductibleAmountIncrement":"","AllowableDeductibleAmount":"","StandardDeductibleAmount":""}]},"Deductible":{"IsthedeductibleEmbeddedorNonEmbedded":"","DeductibleCombinedAndCrossAccumulatorGrid":[{"NetworkTier1":"","NetworkTier2":"","Combined":"","Accums":""}],"DeductibleList":[{"CoverageName":"","NetworkTier":"","NetworkName":"","EmbeddedorNonEmbedded":"","DeductibleAmount":"","EnableUpdate":"False","MandateType":""}]},"MiscellaneousDeductibleGuardrail":{"GuardrailsMiscellaneousDeductibleList":[{"CoverageName":"","NetworkTier":"","NetworkName":"","DeductibleType":"","DeductibleAmountLow":"","DeductibleAmountHigh":"","DeductibleAmountIncrement":"","AllowableDeductibleAmount":"","StandardDeductibleAmount":""}]},"MiscellaneousDeductible":{"MiscellaneousDeductibleList":[{"CoverageName":"","NetworkTier":"","NetworkName":"","DeductibleType":"","DeductibleAmount":"","EnableUpdate":"True","MandateType":""}]},"OutofPocketMaximumGuardrail":{"GuardrailsOutofPocketMaximumList":[{"CoverageName":"","NetworkTier":"","NetworkName":"","EmbeddedorNonEmbedded":"","OOPMAmountLow":"","OOPMAmountHigh":"","OOPMAmountIncrement":"","AllowableOOPMAmount":"","StandardOOPMAmount":""}]},"OutofPocketMaximum":{"IstheOutofPocketEmbeddedorNonEmbedded":"","OutofPocketMaxCombinedAndCrossAccumulatorGrid":[{"NetworkTier1":"","NetworkTier2":"","Combined":"","Accums":""}],"OutofPocketMaximumList":[{"CoverageName":"","NetworkTier":"","NetworkName":"","EmbeddedorNonEmbedded":"","OOPMAmount":"","EnableUpdate":"False","MandateType":""}]},"TotalMaximumOutofPocketTMOOPGuardrail":{"GuardrailsTotalOutofPocketMaximumList":[{"CoverageName":"","NetworkTier":"","NetworkName":"","EmbeddedorNonEmbedded":"","TMOOPAmountLow":"","TMOOPAmountHigh":"","TMOOPAmountIncrement":"","AllowableTMOOPAmount":"","StandardTMOOPAmount":""}]},"TotalMaximumOutofPocketTMOOP":{"IstheTotalOutofPocketEmbeddedorNonEmbedded":"","TotalOutofPocketMaxCombinedAndCrossAccumulatorGrid":[{"NetworkTier1":"","NetworkTier2":"","Combined":"","Accums":"Yes"}],"TotalOutofPocketMaximumList":[{"CoverageName":"","NetworkTier":"","NetworkName":"","EmbeddedorNonEmbedded":"","TMOOPAmount":"","EnableUpdate":"True","MandateType":""}]}},"StandardServices":{"ServiceGroup":"","ServiceGroupInformation":"","StandardServiceList":[{"CostShareGroup":"","BenefitServiceCode":"","BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","BenefitCategory4":"","BenefitCategory5":"","PlaceofService":"","TieredErrorFlag":""}]},"AdditionalServices":{"AdditionalServicesListGuardrail":{"GuardrailsAdditionalServicesList":[{"SelectAllowableService":"False","BenefitServiceCode":"","BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","BenefitCategory4":"","BenefitCategory5":"","PlaceofService":"","CostShareGroup":""}]},"AdditionalServiceList":[{"SelectService":"False","BenefitServiceCode":"","BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","BenefitCategory4":"","BenefitCategory5":"","PlaceofService":"","CostShareGroup":""}]},"CascadingCostShare":{"CostShareGuardrail":{"GuardrailsCostShareGroupList":[{"CostShareGroup":"","NetworkTier":"","NetworkName":"","AllowableCostShareType":"","StandardCostShareType":"","CopayValueLow":"","CopayValueHigh":"","CopayValueIncrement":"","AllowableCopayValue":"","StandardCopayValue":"","AllowableCopayFrequency":"","StandardCopayFrequency":"","AllowableCopaySupplement":"","StandardCopaySupplement":"","CoinsuranceAmountLow":"","CoinsuranceAmountHigh":"","CoinsuranceAmountIncrement":"","AllowableCoinsuranceAmount":"","StandardCoinsuranceAmount":"","RefreshCoinsuranceGuardrail":"Yes","DollarMaxLow":"","DollarMaxHigh":"","DollarMaxIncrement":"","AllowableDollarMax":"","StandardDollarMax":"","AllowableDollarMaxType":"","StandardDollarMaxType":"","SlidingCostShareIntervalGuardrail":"","VariationTypeGuardrail":"","DifferentialTypeGuardrail":"","DifferentialCostShareLevel":"","MultipleGRCostShareLevel":""}]},"CostShareGroup":{"CostShareGroupList":[{"CostShareGroup":"","NetworkTier":"","NetworkName":"","CostShareType":"","CopayValue":"","CopayFrequency":"","CopaySupplement":"","CoinsuranceAmount":"","RefreshCoinsurance":"Yes","SlidingCostShareInterval":"","DollarMax":"","DollarMaxType":"","VariationType":"","DifferentialType":"","SameAsNetworkTier":"","SameAsCostShare":"","EnableUpdate":"False","MandateType":"","ApplyRowVisibility":"","ApplyRowDisability":""}]}},"SlidingCostShare":{"SlidingCostShareGuardrail":{"GuardrailsSlidingCostShareList":[{"CostShareGroup":"","NetworkTier":"","NetworkName":"","SlidingCostShareInterval":"","CostShareInterval":"","VariationType":"","DifferentialType":"","AllowableCostShareType":"","StandardCostShareType":"","StartIntervalLow":"","StartIntervalHigh":"","StartIntervalIncrement":"","AllowableStartInterval":"","StandardStartInterval":"","EndIntervalLow":"","EndIntervalHigh":"","EndIntervalIncrement":"","AllowableEndInterval":"","StandardEndInterval":"","AllowableIntervalType":"","StandardIntervalType":"","CopayValueLow":"","CopayValueHigh":"","CopayValueIncrement":"","AllowableCopayValue":"","StandardCopayValue":"","AllowableCopayFrequency":"","StandardCopayFrequency":"","AllowableCopaySupplement":"","StandardCopaySupplement":"","CoinsuranceAmountLow":"","CoinsuranceAmountHigh":"","CoinsuranceAmountIncrement":"","AllowableCoinsuranceAmount":"","StandardCoinsuranceAmount":"","RefreshCoinsuranceGuardrail":"Yes","DollarMaxLow":"","DollarMaxHigh":"","DollarMaxIncrement":"","AllowableDollarMax":"","StandardDollarMax":"","AllowableDollarMaxType":"","StandardDollarMaxType":""}]},"SlidingCostShareGroup":{"SlidingCostShareList":[{"CostShareGroup":"","NetworkTier":"","NetworkName":"","VariationType":"","DifferentialType":"","SlidingCostShareInterval":"","CostShareInterval":"","CostShareType":"","StartInterval":"","EndInterval":"","IntervalType":"","CopayValue":"","CopayFrequency":"","CopaySupplement":"","CoinsuranceAmount":"","RefreshCoinsurance":"Yes","DollarMax":"","DollarMaxType":"","ApplyRowVisibility":"","ApplyRowDisability":""}]}},"Limits":{"AllowableLimits":{"AllowableLimitsList":[{"AllowedLimits":"False","LimitDescription":"","CombinedorNonCombined":"","AllowableLimitType":"","AllowableLimit2Type":"","AllowableOperators":""}]},"LimitsGuardrail":{"GuardrailsLimitInformationDetail":[{"LimitDescription":"","NetworkTier":"","NetworkName":"","LimitType":"","LimitAmountLow":"","LimitAmountHigh":"","LimitAmountIncrement":"","AllowableLimitAmount":"","StandardLimitAmount":"","AllowableLimitFrequency":"","StandardLimitFrequency":"","LimitStartLow":"","LimitStartHigh":"","LimitStartIncrement":"","AllowableLimitStart":"","StandardLimitStart":"","LimitStopLow":"","LimitStopHigh":"","LimitStopIncrement":"","AllowableLimitStop":"","StandardLimitStop":"","AllowableLimitStartStopType":"","StandardLimitStartStopType":"","MLServiceList":[{"BenefitServiceCode":"","BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","BenefitCategory4":"","BenefitCategory5":"","PlaceofService":""}]}],"GuardrailsLimit2InformationDetail":[{"LimitDescription":"","NetworkTier":"","NetworkName":"","Limit2Type":"","Limit2AmountLow":"","Limit2AmountHigh":"","Limit2AmountIncrement":"","AllowableLimit2Amount":"","StandardLimit2Amount":"","AllowableLimit2Frequency":"","StandardLimit2Frequency":"","Limit2StartLow":"","Limit2StartHigh":"","Limit2StartIncrement":"","AllowableLimit2Start":"","StandardLimit2Start":"","Limit2StopLow":"","Limit2StopHigh":"","Limit2StopIncrement":"","AllowableLimit2Stop":"","StandardLimit2Stop":"","AllowableLimit2StartStopType":"","StandardLimit2StartStopType":"","MLServiceList":[{"BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","PlaceofService":"","BenefitServiceCode":"","BenefitCategory4":"","BenefitCategory5":""}]}]},"LimitsInformation":{"LimitList":[{"LimitDescription":"","CombinedorNonCombined":"","AllowedLimits":"","BenefitServiceCode":"","BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":""}],"LimitInformationDetail":[{"LimitDescription":"","NetworkTier":"","NetworkName":"","Combined":"","Accums":"","LimitType":"","LimitAmount":"","LimitFrequency":"","LimitStart":"","LimitStop":"","LimitStartStopType":"","LimitAdditionalDetails":"","Operator":"NA","Limit2Amount":"","Limit2Type":"","Limit2Frequency":"","Limit2Start":"","Limit2Stop":"","Limit2StartStopType":"","Limit2AdditionalDetails":"","MandateType":"","EnableUpdate":"True","ServiceName":"","MLServiceList":[{"BenefitServiceCode":"","BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","BenefitCategory4":"","BenefitCategory5":"","PlaceofService":""}]}]}},"BenefitReviewGuardrail":{"BenefitReviewGuardrail":{"Copay":"True","Coinsurance":"True","IndDeductible":"False","TwoPersonDeductible":"False","FamDeductible":"False","IndOOPM":"False","TwoPersonOOPM":"False","FamilyOOPM":"False","PenaltyAmount":"True","DollarMax":"True"},"GuardrailsBenefitReviewGrid":[{"CostShareGroup":"","BenefitServiceCode":"","NetworkTier":"","BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","BenefitCategory4":"","BenefitCategory5":"","PlaceofService":"","NetworkName":"","ManualOverride":"False","AllowableDeductibleType":"","AllowableCostShareType":"","StandardCostShareType":"","CopayLow":"","CopayHigh":"","CopayIncrement":"","AllowableCopay":"","StandardCopay":"","AllowableCopayFrequency":"","StandardCopayFrequency":"","AllowableCopaySupplement":"","StandardCopaySupplement":"","CoinsuranceLow":"","CoinsuranceHigh":"","CoinsuranceIncrement":"","AllowableCoinsurance":"","StandardCoinsurance":"","DollarMaxLow":"","DollarMaxHigh":"","DollarMaxIncrement":"","AllowableDollarMax":"","StandardDollarMax":"","AllowableDollarMaxType":"","StandardDollarMaxType":"","IndDeductibleLow":"","IndDeductibleHigh":"","IndDeductibleIncrement":"","AllowableIndDeductible":"","StandardIndDeductible":"","TwoPersonDeductibleLow":"","TwoPersonDeductibleHigh":"","TwoPersonDeductibleIncrement":"","AllowableTwoPersonDeductible":"","StandardTwoPersonDeductible":"","FamDeductibleLow":"","FamDeductibleHigh":"","FamDeductibleIncrement":"","AllowableFamDeductible":"","StandardFamDeductible":"","IndOOPMLow":"","IndOOPMHigh":"","IndOOPMIncrement":"","AllowableIndOOPM":"","StandardIndOOPM":"","TwoPersonOOPMLow":"","TwoPersonOOPMHigh":"","TwoPersonOOPMIncrement":"","AllowableTwoPersonOOPM":"","StandardTwoPersonOOPM":"","FamilyOOPMLow":"","FamilyOOPMHigh":"","FamilyOOPMIncrement":"","AllowableFamilyOOPM":"","StandardFamilyOOPM":"","PenaltyAmountLow":"","PenaltyAmountHigh":"","PenaltyAmountIncrement":"","AllowablePenaltyAmount":"","StandardPenaltyAmount":"","SlidingCostShareIntervalGuardrail":"","ServiceQualifier":"","TieredErrorFlag":"","DifferentialCostShareLevel":"","MultipleGRCostShareLevel":"","VariationType":"","DifferentialType":""}],"BenefitReviewSlidingCostShareGuardrail":{"GuardrailBenefitReviewSlidingCostShare":[{"CostShareGroup":"","BenefitServiceCode":"","NetworkTier":"","BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","BenefitCategory4":"","BenefitCategory5":"","PlaceofService":"","NetworkName":"","ManualOverride":"False","AllowableDeductibleType":"","CostShareInterval":"","SlidingCostShareInterval":"","VariationType":"","DifferentialType":"","AllowableCostShareType":"","StandardCostShareType":"","StartIntervalLow":"","StartIntervalHigh":"","StartIntervalIncrement":"","AllowableStartInterval":"","StandardStartInterval":"","EndIntervalLow":"","EndIntervalHigh":"","EndIntervalIncrement":"","AllowableEndInterval":"","StandardEndInterval":"","AllowableIntervalType":"","StandardIntervalType":"","CopayLow":"","CopayHigh":"","CopayIncrement":"","AllowableCopay":"","StandardCopay":"","AllowableCopayFrequency":"","StandardCopayFrequency":"","AllowableCopaySupplement":"","StandardCopaySupplement":"","CoinsuranceLow":"","CoinsuranceHigh":"","CoinsuranceIncrement":"","AllowableCoinsurance":"","StandardCoinsurance":"","DollarMaxLow":"","DollarMaxHigh":"","DollarMaxIncrement":"","AllowableDollarMax":"","StandardDollarMax":"","AllowableDollarMaxType":"","StandardDollarMaxType":"","IndDeductibleLow":"","IndDeductibleHigh":"","IndDeductibleIncrement":"","AllowableIndDeductible":"","StandardIndDeductible":"","TwoPersonDeductibleLow":"","TwoPersonDeductibleHigh":"","TwoPersonDeductibleIncrement":"","AllowableTwoPersonDeductible":"","StandardTwoPersonDeductible":"","FamDeductibleLow":"","FamDeductibleHigh":"","FamDeductibleIncrement":"","AllowableFamDeductible":"","StandardFamDeductible":"","IndOOPMLow":"","IndOOPMHigh":"","IndOOPMIncrement":"","AllowableIndOOPM":"","StandardIndOOPM":"","TwoPersonOOPMLow":"","TwoPersonOOPMHigh":"","TwoPersonOOPMIncrement":"","AllowableTwoPersonOOPM":"","StandardTwoPersonOOPM":"","FamilyOOPMLow":"","FamilyOOPMHigh":"","FamilyOOPMIncrement":"","AllowableFamilyOOPM":"","StandardFamilyOOPM":"","PenaltyAmountLow":"","PenaltyAmountHigh":"","PenaltyAmountIncrement":"","AllowablePenaltyAmount":"","StandardPenaltyAmount":"","TieredErrorFlag":""}]}},"BenefitReview":{"BenefitReviewGrid":[{"CostShareGroup":"","BenefitServiceCode":"","NetworkTier":"","BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","BenefitCategory4":"","BenefitCategory5":"","PlaceofService":"","NetworkName":"","ManualOverride":"True","DeductibleType":"","CostShareType":"","Covered":"True","Limits":"","Copay":"","CopayFrequency":"","CopaySupplement":"","Coinsurance":"","DollarMax":"","DollarMaxType":"","IndDeductible":"","TwoPersonDeductible":"","FamDeductible":"","IndOOPM":"","TwoPersonOOPM":"","FamilyOOPM":"","PenaltyAmount":"","PriorApproval":"","Referral":"","MandateType":"","SlidingCostShareIntervalGuardrail":"","ServiceQualifier":"","TieredErrorFlag":"","VariationType":"","DifferentialType":"","SameAsCostShare":"","SameAsNetworkTier":"","ApplyRowVisibility":"","ApplyRowDisability":""}],"BenefitReviewSlidingCostShare":{"BenefitReviewGridSlidingCostShare":[{"CostShareGroup":"","BenefitServiceCode":"","NetworkTier":"","BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","BenefitCategory4":"","BenefitCategory5":"","PlaceofService":"","NetworkName":"","ManualOverride":"False","DeductibleType":"","CostShareType":"","SlidingCostShareInterval":"","CostShareInterval":"","VariationType":"","DifferentialType":"","StartInterval":"","EndInterval":"","IntervalType":"","Covered":"False","Limits":"","Copay":"","CopayFrequency":"","CopaySupplement":"","Coinsurance":"","DollarMax":"","DollarMaxType":"","IndDeductible":"","TwoPersonDeductible":"","FamDeductible":"","IndOOPM":"","TwoPersonOOPM":"","FamilyOOPM":"","PenaltyAmount":"","PriorApproval":"","Referral":"","MandateType":"","TieredErrorFlag":"","ApplyRowVisibility":"","ApplyRowDisability":""}]}},"CombinedCostShare":{"CombinedCostShareGuardrail":{"AllowableCombinedCostShareCategory":[{"AllowedCombinedCostShareCategories":"","CombinedCostShareDescription":"","CombinedNetwork":"","CombinedCostShareType":""}],"GuardrailsCombinedCostShareGroupList":[{"CombinedCostShareDescription":"","CombinedNetwork":"","CombinedCostShareType":"","CombinedCostShareValueLow":"","CombinedCostShareValueHigh":"","CombinedCostShareValueIncrement":"","AllowableCombinedCostShareValue":"","StandardCombinedCostShareValue":"","AllowableCostShareFrequency":"","StandardCostShareFrequency":"","MLServiceList":[{"BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","PlaceofService":"","BenefitServiceCode":"","BenefitCategory4":"","BenefitCategory5":"","ServiceName":""}]}]},"CombinedCostShareGroup":{"CombinedCostShareCategoryList":[{"CombinedCostShareDescription":"","CombinedNetwork":""}],"CombinedCostShareGroupList":[{"CombinedCostShareDescription":"","CombinedNetwork":"","CombinedCostShareType":"","CombinedCostShareValue":"","CombinedCostShareFrequency":"","MLServiceList":[{"BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","PlaceofService":"","BenefitServiceCode":"","BenefitCategory4":"","BenefitCategory5":"","ServiceName":""}]}]}},"RxProductRules":{"RxProductInformation":{"FoundationTemplate":"","ProductID":"","LineofBusiness":"Prescription","PackageName":"","PlanEffectiveDate":"","PlanRenewalDate":"","MarketSegment":"","State":"","Region":"","FundingArrangement":"","SpendingAccount":"","FormularyType":"","BenefitPeriod":"","CDHIndicator":"","CDHType":"","PlanMonth":"","OptionNumber":"","TypeofPlan":"","GrandfatheredPlan":"","FiledLegalEntityinnetworkentity":"","FiledLegalEntityoutofnetworkentity":"","PackageNameFacetsName":"","BSBS":"","RenewalStatus":"","ExclusiveSpecialtyProviderNetworkESPN":"","ExtraCareHealthCareCard":"","RxNetwork":"","Tiers":""},"RxPlanRequirements":{"RxPlanRequirementDetails":[{"RxBenefits":"","BenefitOptions":""}]},"MandatesRequirements":{"MandatesRequirementDetails":[{"Mandates":"","MandatesOptions":""}]},"ASOOnlyOptions":{"ASOOnlyOptionsDetails":[{"ASOOnlyOptionsList":"","Allowed":""}]}},"RxNetworkandTierSelection":{"RxNetwork":{"RxNetworkList":[{"NetworkTier":"","NetworkName":""}]},"RxCoverageLevelList":[{"CoverageName":"","CoverageDisplayName":""}],"DayRanges":{"AllowableDayRanges":[{"DayRanges":"","RangeNumber":"","DayStart":"","DayEnd":""}]},"RxNetworkTierGuardrail":{"GuardrailsRxNetworkTierList":[{"NetworkTier":"","RxTier":"","RxTierType":"","AllowableDayRanges":""}]}},"RxNetworkTier":{"RxNetworkTierList":[{"NetworkName":"","NetworkTier":"","RxTier":"","RxTierType":"","DayRanges":""}]},"RxGeneralCostShare":{"RxGeneralCostShareGuardrail":{"GuardrailsRxCostShareList":[{"NetworkName":"","NetworkTier":"","CoverageName":"","RxDeductibleAmountLow":"","RxDeductibleAmountHigh":"","RxDeductibleAmountIncrement":"","AllowableRxDeductibleAmount":"","StandardRxDeductibleAmount":"","RxOOPMAmountLow":"","RxOOPMAmountHigh":"","RxOOPMAmountIncrement":"","AllowableRxOOPMAmount":"","StandardRxOOPMAmount":"","RxTMOOPAmountLow":"","RxTMOOPAmountHigh":"","RxTMOOPAmountIncrement":"","AllowableRxTMOOPAmount":"","StandardRxTMOOPAmount":""}]},"RxCostShare":{"CombinedAndCrossAccumulatorGrid":[{"NetworkTier1":"","NetworkTier2":"","CombinedRxDeductible":"No","AccumsRxDeductible":"","CombinedRxOOPM":"","AccumsRxOOPM":"","CombinedRxTMOOP":"","AccumsRxTMOOP":""}],"RxCostShareList":[{"NetworkName":"","NetworkTier":"","CoverageName":"","RxDeductibleAmount":"","RxOOPMAmount":"","RxTMOOPAmount":"","MandateType":""}]}},"RxBenefitReview":{"RxBenefitReviewGuardrail":{"GuardrailsRxBenefitReviewGrid":[{"NetworkName":"","NetworkTier":"","RxTier":"","RxTierType":"","DayRanges":"","RangeNumber":"","AllowableCostShareType":"","StandardCostShareType":"","RxCopayLow":"","RxCopayHigh":"","RxCopayIncrement":"","AllowableRxCopay":"","StandardRxCopay":"","AllowableRxCopayFrequency":"","StandardRxCopayFrequency":"","DollarMaxLow":"","DollarMaxHigh":"","DollarMaxIncrement":"","AllowableDollarMax":"","StandardDollarMax":"","RxCoinsuranceLow":"","RxCoinsuranceHigh":"","RxCoinsuranceIncrement":"","AllowableRxCoinsurance":"","StandardRxCoinsurance":""}]},"RxBenefitReviewGrid":[{"NetworkName":"","NetworkTier":"","RxTier":"","RxTierType":"","DayRanges":"","RangeNumber":"","CostShareType":"","Covered":"True","RxCopay":"","RxCopayFrequency":"","DollarMax":"","RxCoinsurance":"","IndividualRxDeductible":"","FamilyRxDeductible":"","IndividualRxOOPM":"","FamilyRxOOPM":"","IndividualRxTMOOP":"","FamilyRxTMOOP":"","PriorApproval":"","Referral":"","MandateType":"","ApplyRowVisibility":"","ApplyRowDisability":""}]},"DentalProductRules":{"DentalProductInformation":{"FoundationTemplate":"","ProductID":"","LineofBusiness":"","PackageName":"","PlanEffectiveDate":"","PlanRenewalDate":"","MarketSegment":"","FundingArrangement":"","State":"","Region":"","SpendingAccount":"","BenefitPeriod":"","PlanMonth":"","TypeofPlan":"","NetworkNameinareaonlyexceptforEmergencyandUrgentCareServices":"","NetworkNameoutofarea":"","GrandfatheredPlan":"","FiledLegalEntity":"","PackageNameFacetsName":"","BSBS":"","RenewalStatus":"","GovernmentMandates":"","VoluntaryNonVoluntary":"","BlueBusinessNonBlueBusiness":""}},"DentalNetworkandClass":{"DentalNetwork":{"DentalNetworkList":[{"DentalNetworkTier":""}]},"DentalCoverage":{"DentalCoverageList":[{"DentalCoverage":"","DentalCoverageName":""}]},"DentalClass":{"DentalClassSelection":[{"DentalClass":"","DentalClassName":"","MLDentalServiceList":[{"DentalServiceName":"","BenefitServiceCode":"","BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","PlaceofService":""}]}]}},"DentalDeductibleandMaximum":{"DentalDeductibleandMaximumsGuardrail":{"GuardrailsDentalDeductibleMaximumsList":[{"DentalNetworkTier":"","DentalCoverage":"","DentalDeductibleAmountLow":"","DentalDeductibleAmountHigh":"","DentalDeductibleAmountIncrement":"","AllowableDentalDeductibleAmount":"","StandardDentalDeductibleAmount":"","DentalOOPMAmountLow":"","DentalOOPMAmountHigh":"","DentalOOPMAmountIncrement":"","AllowableDentalOOPMAmount":"","StandardDentalOOPMAmount":"","DentalTMOOPAmountLow":"","DentalTMOOPAmountHigh":"","DentalTMOOPAmountIncrement":"","AllowableDentalTMOOPAmount":"","StandardDentalTMOOPAmount":""}]},"DentalCostShare":{"DentalDeductibleMaximumsList":[{"DentalNetworkTier":"","DentalCoverage":"","DentalDeductibleAmount":"","DentalOOPMAmount":"","MandateType":""}]}},"DentalClassCostShare":{"DentalClassCostShareGuardrail":{"GuardrailsDentalClassCostShare":[{"DentalNetworkTier":"","DentalClass":"","DentalClassName":"","AllowableCostShareType":"","StandardCostShareType":"","DentalCopayLow":"","DentalCopayHigh":"","DentalCopayIncrement":"","AllowableDentalCopay":"","StandardDentalCopay":"","AllowableDentalCopayFrequency":"","StandardDentalCopayFrequency":"","DentalCoinsuranceLow":"","DentalCoinsuranceHigh":"","DentalCoinsuranceIncrement":"","AllowableDentalCoinsurance":"","StandardDentalCoinsurance":"","WaitingPeriodLow":"","WaitingPeriodHigh":"","WaitingPeriodIncrement":"","AllowableWaitingPeriod":"","StandardWaitingPeriod":"","DentalDollarMaxLow":"","DentalDollarMaxHigh":"","DentalDollarMaxIncrement":"","AllowableDentalDollarMax":"","StandardDentalDollarMax":""}]},"DentalClassCostShare":[{"DentalNetworkTier":"","DentalClass":"","DentalClassName":"","CostShareType":"","DentalCopay":"","DentalCopayFrequency":"","DentalCoinsurance":"","DentalDollarMax":"","WaitingPeriod":"","MandateType":""}]},"DentalLimits":{"AllowableDentalLimits":{"AllowableDentalLimitsList":[{"AllowedLimits":"False","LimitDescription":"","CombinedorNonCombined":"","AllowableLimitType":""}]},"DentalLimitsInformationGuardrail":{"GuardrailsDentalLimitsInformationDetail":[{"LimitDescription":"","DentalNetworkTier":"","LimitType":"","LimitAmountLow":"","LimitAmountHigh":"","LimitAmountIncrement":"","AllowableLimitAmount":"","StandardLimitAmount":"","AllowableLimitFrequency":"","StandardLimitFrequency":"","MLDentalServiceList":[{"BenefitServiceCode":"","BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","DentalServiceName":"","PlaceofService":""}]}]},"DentalLimitInformation":{"DentalLimitInformationList":[{"LimitDescription":"","AllowedLimits":"","CombinedorNonCombined":""}]},"DentalLimitsInformationDetail":{"DentalLimitsInformationDetail":[{"LimitDescription":"","DentalNetworkTier":"","LimitAmount":"","LimitType":"","LimitFrequency":"","AdditionalDetails":"","EnableUpdate":"True","MandateType":"","MLDentalServiceList":[{"BenefitServiceCode":"","BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","DentalServiceName":"","PlaceofService":""}]}]}},"DentalBenefitReview":{"DentalBenefitReviewGuardrail":{"GuardrailsDentalBenefitReview":[{"DentalNetworkTier":"","DentalClass":"","DentalClassName":"","BenefitServiceCode":"","BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","ManualOverride":"False","AllowableCostShareType":"","StandardCostShareType":"","DentalCopayLow":"","DentalCopayHigh":"","DentalCopayIncrement":"","AllowableDentalCopay":"","StandardDentalCopay":"","AllowableDentalCopayFrequency":"","StandardDentalCopayFrequency":"","DentalCoinsuranceLow":"","DentalCoinsuranceHigh":"","DentalCoinsuranceIncrement":"","AllowableDentalCoinsurance":"","StandardDentalCoinsurance":"","IndDentalDeductibleLow":"","IndDentalDeductibleHigh":"","IndDentalDeductibleIncrement":"","AllowableIndDentalDeductible":"","StandardIndDentalDeductible":"","FamDentalDeductibleLow":"","FamDentalDeductibleHigh":"","FamDentalDeductibleIncrement":"","AllowableFamDentalDeductible":"","StandardFamDentalDeductible":"","IndDentalOOPMLow":"","IndDentalOOPMHigh":"","IndDentalOOPMIncrement":"","AllowableIndDentalOOPM":"","StandardIndDentalOOPM":"","FamDentalOOPMLow":"","FamDentalOOPMHigh":"","FamDentalOOPMIncrement":"","AllowableFamDentalOOPM":"","StandardFamDentalOOPM":"","IndDentalTMOOPLow":"","IndDentalTMOOPHigh":"","IndDentalTMOOPIncrement":"","AllowableIndDentalTMOOP":"","StandardIndDentalTMOOP":"","FamDentalTMOOPLow":"","FamDentalTMOOPHigh":"","FamDentalTMOOPIncrement":"","AllowableFamDentalTMOOP":"","StandardFamDentalTMOOP":"","WaitingPeriodLow":"","WaitingPeriodHigh":"","WaitingPeriodIncrement":"","AllowableWaitingPeriod":"","StandardWaitingPeriod":"","DentalDollarMaxLow":"","DentalDollarMaxHigh":"","DentalDollarMaxIncrement":"","AllowableDentalDollarMax":"","StandardDentalDollarMax":""}]},"DentalBenefitReview":[{"DentalNetworkTier":"","DentalClass":"","DentalClassName":"","BenefitServiceCode":"","BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","ManualOverride":"False","CostShareType":"","Covered":"True","DentalCopay":"","DentalCopayFrequency":"","DentalCoinsurance":"","WaitingPeriod":"","IndDentalDeductible":"","FamDentalDeductible":"","IndDentalOOPM":"","FamDentalOOPM":"","IndDentalTMOOP":"","FamDentalTMOOP":"","PriorApproval":"","Referral":"","MandateType":"","Limits":"","ApplyRowVisibility":"","ApplyRowDisability":"","DentalDollarMax":"","LifetimeMaximum":""}]},"QHPDetails":{"PlanIdentifiers":{"HIOSIssuerID":"","IssuerState":"","MarketCoverage":"","DentalOnlyPlan":"No","TIN":"","HIOSPlanID":"","PlanMarketingName":"","HIOSProductID":"","HPID":"","ServiceAreaID":"","FormularyID":"","NetworkID":"","MetalTier":"","CSRVariationType":"","PlanIDCSRSuffix":"","URLforEnrollmentPayment":"","AutoGenerateVariations":""},"Planattributes":{"NewExistingPlan":"","PlanType":"","DesignType":"Not Applicable","UniquePlanDesign":"","Blank":"","IssuerActuarialValue":"","QHPNonQHP":"","NoticePeriodforPregnancy":"","IsaReferralRequiredforaSpecialist":"","SpecialistsRequiringaReferral":"","PlanLevelExclusions":"","LimitedCostSharingPlanVariationEstAdvancedPayment":"","DoesthisplanofferCompositeRating":"No","ChildOnlyOffering":"","ChildOnlyPlanID":"","TobaccoWellnessProgramOffered":"","DiseaseManagementProgramsOffered":"","EHBPercentofTotalPremium":"","RXDefaultcoinsuranceforQHP":""},"StandAloneDentalOnlyList":{"EHBApportionmentforPediatricDental":"","GuaranteedVsEstimatedRate":""},"GeographicCoverageList":{"OutofCountryCoverage":"","OutofCountryCoverageDescription":"","OutofServiceAreaCoverage":"","OutofServiceAreaCoverageDescription":"","NationalNetwork":""},"PlanCostSharingAttributes":{"PlanVariantMarketingName":"","MedicalAndDrugDeductiblesIntegrated":"","MedicalAndDrugMaximumOutofPocketIntegrated":"","Doyouhaveanydeductiblesubgroups":"No","Howmanydeductiblesubgroupsdoyouhave":"","Whatisthenameofthisdeductiblesubgroup":"","MultipleInNetworkTiers":"","FirstTierUtilization":"","SecondTierUtilization":"","PlanVariantMarketingNameOnExchange":"","PlanVariantMarketingNameZeroCostSharing":"","PlanVariantMarketingNameLimitedCostSharing":""},"HSAHRADetailList":{"HSAEligible":"","HSAHRAEmployerContribution":"","HSAHRAEmployerContributionAmount":""},"PlanVariantLevelURLsList":{"URLforSummaryofBenefitsCoverage":"","PlanBrochure":""},"AVCalculatorAdditionalBenefitDesignList":{"MaximumCoinsuranceforSpecialtyDrugs":"","MaximumNumberofDaysforCharginganInpatientCopay":"","BeginPrimaryCareCostSharingAfteraSetNumberofVisits":"","BeginPrimaryCareDeductibleCoinsuranceAfteraSetNumberofCopays":"","AVValues":""},"BenefitInformation":{"QHPBenefitInformation":[{"Benefits":"","EHB":"","IsthisBenefitCovered":"","QuantitativeLimitonService":"","LimitQuantity":"","LimitUnit":"","LimitValidation":"","ExclusionName":"","BenefitName":"","LimitDescription":"","EHBVarianceReason":"","ExcludedfromInNetworkMOOP":"","ExcludedfromOutofNetworkMOOP":""}]}},"AdditionalBenefitPrograms":{"GuardrailsAdditionalBenefitProgramGrid":[{"Include":"","AdditionalBenefitProgram":"","NetworkTier":"","NetworkName":""}],"AdditionalBenefitProgramGrid":[{"Include":"True","AdditionalBenefitProgram":"","NetworkTier":"","NetworkName":"","DiscountReimbursement":""}]},"Riders":{"RiderList":[{"RiderName":""}]},"AuditChecklist":{"IsAuditRequired":"","GeneralAuditInfo":{"QID":"","GroupID":"","GroupName":"","AssignedTo":"","AuditType":""},"ChecklistDetails":{"ProductSetup":"","ProductSetupError":"","ProductSetupPoints":"5","ProductSetupPossiblePoints":"5","DeductibleSetup":"","DeductibleError":"","DeductiblePoints":"2","DeductiblePossiblePoints":"2","OutofPocketMaximumSetup":"","OutofPocketMaximumError":"","OutofPocketMaximumPoints":"2","OutofPocketMaximumPossiblePoints":"2","CoinsuranceSetup":"","CoinsuranceError":"2","CoinsurancePoints":"2","CoinsurancePossiblePoints":"2","CopaySetup":"","CopayError":"","CopayPoints":"4","CopayPossiblePoints":"4","LimitsSetup":"","LimitsError":"","LimitsPoints":"5","LimitsPossiblePoints":"5","RidersSetup":"","RidersError":"","RidersPoints":"5","RidersPossiblePoints":"5","RxPackageSetup":"","RxPackageError":"","RxPackagePoints":"5","RxPackagePossiblePoints":"5","AncillaryDentalSetup":"","AncillaryDentalError":"","AncillaryDentalPoints":"5","AncillaryDentalPossiblePoints":"5","AncillaryVisionSetup":"","AncillaryVisionError":"","AncillaryVisionPoints":"5","AncillaryVisionPossiblePoints":"5","AncillaryHearingSetup":"","AncillaryHearingError":"","AncillaryHearingPoints":"5","AncillaryHearingPossiblePoints":"5","QHPDetailsSetup":"","QHPDetailsError":"","QHPDetailsPoints":"5","QHPDetailsPossiblePoints":"5","TotalPointsPossible":"","AuditScore":"","AuditPercent":""},"ApprovalDetails":{"CompletedBy":"","DateCompleted":""}},"HSA":{"HSAProductInformation":{"PackageName":"","ProductID":"","ProductType":"","ProductTemplateTypeCode":"","AllowableHSAProductWideProvisions":[{"Select":"False","ServiceNameSERVICEPROVISION":"","ProvisionTextOptions":""}],"SelectHSAProductWideProvisions":[{"ProvisionNameSERVICEPROVISION":"","ProvisionTextOptions":""}]}},"VisionProductRules":{"VisionProductInformation":{"FoundationTemplate":"","ProductID":"","LineofBusiness":"","PackageName":"","PlanEffectiveDate":"","PlanRenewalDate":"","MarketSegment":"","FiledLegalEntity":"","State":"","Region":"","FundingArrangement":"","SpendingAccount":"","BenefitPeriod":"","PlanMonth":"","PlanType":"","NetworkNameinareaonlyexceptforEmergencyandUrgentCareServices":"","NetworkNameoutofarea":"","GrandfatheredPlan":"","PackageNameFacetsName":"","BSBS":"","RenewalStatus":"","GovernmentMandates":"","VoluntaryNonVoluntary":"","BlueBusinessNonBlueBusiness":""}},"VisionNetworkSelection":{"VisionNetwork":{"VisionNetworkList":[{"VisionNetworkTier":""}]},"VisionCoverage":{"VisionCoverageList":[{"VisionCoverage":"","VisionCoverageName":""}]},"VisionServices":{"VisionServicesList":[{"VisionServiceName":"","BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","PlaceofService":"","BenefitServiceCode":""}]}},"VisionDeductibleMaximum":{"VisionDeductibleMaximumGuardrail":{"GuardrailsVisionDeductibleMaximumsList":[{"VisionNetworkTier":"","VisionCoverage":"","VisionDeductibleAmountLow":"","VisionDeductibleAmountHigh":"","VisionDeductibleAmountIncrement":"","AllowableVisionDeductibleAmount":"","StandardVisionDeductibleAmount":"","VisionOOPMAmountLow":"","VisionOOPMAmountHigh":"","VisionOOPMAmountIncrement":"","AllowableVisionOOPMAmount":"","StandardVisionOOPMAmount":"","VisionTMOOPAmountLow":"","VisionTMOOPAmountHigh":"","VisionTMOOPAmountIncrement":"","AllowableVisionTMOOPAmount":"","StandardVisionTMOOPAmount":""}]},"VisionCostShare":{"VisionDeductibleMaximumsList":[{"VisionNetworkTier":"","VisionCoverage":"","VisionDeductibleAmount":"","VisionOOPMAmount":"","MandateType":"","VisionTMOOPAmount":""}]}},"VisionLimits":{"AllowableVisionLimits":{"AllowableVisionLimitsList":[{"AllowedLimits":"False","LimitDescription":"","CombinedorNonCombined":"","AllowableLimitType":""}]},"VisionLimitsInformationGuardrail":{"GuardrailsVisionLimitsInformationDetail":[{"LimitDescription":"","VisionNetworkTier":"","LimitType":"","LimitAmountLow":"","LimitAmountHigh":"","LimitAmountIncrement":"","AllowableLimitAmount":"","StandardLimitAmount":"","AllowableLimitFrequency":"","StandardLimitFrequency":"","MLVisionServiceList":[{"BenefitServiceCode":"","BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","VisionServiceName":"","PlaceofService":""}]}]},"VisionLimitInformation":{"VisionLimitInformationList":[{"LimitDescription":"","AllowedLimits":"","CombinedorNonCombined":""}]},"VisionLimitsInformationDetail":{"VisionLimitsInformationDetail":[{"LimitDescription":"","VisionNetworkTier":"","LimitAmount":"","LimitType":"","LimitFrequency":"","AdditionalDetails":"","EnableUpdate":"True","MandateType":"","MLVisionServiceList":[{"BenefitServiceCode":"","BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","VisionServiceName":"","PlaceofService":""}]}]}},"VisionBenefitReview":{"VisionBenefitReviewGuardrail":{"GuardrailsVisionBenefitReview":[{"VisionNetworkTier":"","BenefitServiceCode":"","BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","AllowableCostShareType":"","StandardCostShareType":"","VisionCopayLow":"","VisionCopayHigh":"","VisionCopayIncrement":"","AllowableVisionCopay":"","StandardVisionCopay":"","AllowableVisionCopayFrequency":"","StandardVisionCopayFrequency":"","VisionCoinsuranceLow":"","VisionCoinsuranceHigh":"","VisionCoinsuranceIncrement":"","AllowableVisionCoinsurance":"","StandardVisionCoinsurance":"","IndVisionDeductibleLow":"","IndVisionDeductibleHigh":"","IndVisionDeductibleIncrement":"","AllowableIndVisionDeductible":"","StandardIndVisionDeductible":"","FamVisionDeductibleLow":"","FamVisionDeductibleHigh":"","FamVisionDeductibleIncrement":"","AllowableFamVisionDeductible":"","StandardFamVisionDeductible":"","IndVisionOOPMLow":"","IndVisionOOPMHigh":"","IndVisionOOPMIncrement":"","AllowableIndVisionOOPM":"","StandardIndVisionOOPM":"","FamVisionOOPMLow":"","FamVisionOOPMHigh":"","FamVisionOOPMIncrement":"","AllowableFamVisionOOPM":"","StandardFamVisionOOPM":"","IndVisionTMOOPLow":"","IndVisionTMOOPHigh":"","IndVisionTMOOPIncrement":"","AllowableIndVisionTMOOP":"","StandardIndVisionTMOOP":"","FamVisionTMOOPLow":"","FamVisionTMOOPHigh":"","FamVisionTMOOPIncrement":"","AllowableFamVisionTMOOP":"","StandardFamVisionTMOOP":"","VisionDollarMaxLow":"","VisionDollarMaxHigh":"","VisionDollarMaxIncrement":"","AllowableVisionDollarMax":"","StandardVisionDollarMax":""}]},"VisionBenefitReview":[{"VisionNetworkTier":"","BenefitServiceCode":"","BenefitCategory1":"","BenefitCategory2":"","BenefitCategory3":"","CostShareType":"","Covered":"True","VisionCopay":"","VisionCopayFrequency":"","VisionCoinsurance":"","IndVisionDeductible":"","FamVisionDeductible":"","IndVisionOOPM":"","VisionDollarMax":"","Discount":"","LifetimeMaximum":"","FamVisionOOPM":"","IndVisionTMOOP":"","FamVisionTMOOP":"","PriorApproval":"","Referral":"","MandateType":"","Limits":"","ApplyRowVisibility":"","ApplyRowDisability":""}]},"Rates":{"RateList":[{"ProductID":"","ProductType":"","Individual":"","ParentChild":"","ParentChildren":"","TwoPerson":"","Family":"","GrossPCPM":"","Retention":"","RxRebate":"","NetPCPM":"","PRBAFwDSF":""}],"PackageRateList":[{"PackageID":"","Individual":"","ParentChild":"","ParentChildren":"","TwoPerson":"","Family":"","GrossPCPM":"","Retention":"","RxRebate":"","NetPCPM":"","PRBAFwDSF":""}]},"SystemConfiguration":{"UserRole":"Simplify SuperUser","UserRoleGroupforVisibility":"Group V1","UserRoleGroupforDisability":""},"Networks":{"MedicalNetworkTierList":null,"RxNetworkTierList":null,"DentalNetworkTierList":null,"VisionNetworkTierList":null}}'

					INSERT INTO Fldr.Forminstance (TenantID, AddedDate, AddedBy, UpdatedDate, UpdatedBy, FolderVersionID,
												FormDesignID, FormDesignVersionID, Name, DOCID, IsActive, AnchorDocumentID,FormInstanceMapTypeId)
					SELECT @TenantID AS TenantID
						, @Date AS AddedDate
						, @AddedBy AS AddedBy
						, NULL AS UpdatedDate
						, NULL AS UpdatedBy
						, @FolderVersionId AS FolderVersionID
						, @FormID AS FormDesignID
						, @FormDesignVersionID AS FormDesignVersionID
						, @PlanName AS Name
						, 0 AS DocID
						, 1 AS IsActive
						, 0 AS AnchorDocumentID
						, ISNULL(@ProductTypeId,0)

					SET @FormInstanceId = SCOPE_IDENTITY()
					SET @FormInstanceId_Business = @FormInstanceId;

					UPDATE Fldr.Forminstance
					SET DOCID = @FormInstanceId
					WHERE Forminstanceid = @FormInstanceId

					UPDATE Fldr.Forminstance
					SET AnchorDocumentID = @FormInstanceId_Business
					WHERE Forminstanceid = @FormInstanceId

					INSERT INTO Fldr.FormInstanceDataMap (FormInstanceID, ObjectInstanceID, FormData, CompressJsonData)
					SELECT @FormInstanceId, 0 AS ObjectInstanceID, @FormData AS FormData, NULL AS CompressJsonData

					SET @FormData = NULL;

					----------------------------------------------------------------------------------------------------------------
					--Medical
					SET @FormData='{"SearchFields":{"FoundationTemplate":"","ProductID":"","ProductName":"","TypeofPlan":"","PlanEffectiveDate":"","BenefitPeriod":"","State":"","DeductibleOptions":"","OOPMOptions":"","MarketSegment":"","FundingArrangement":"","Module":"","IsthisaGrandfatheredPlan":"","ProductType":"","CoinsuranceList":[{"CoinsuranceAmount":"","NetworkTier":""}],"DeductibleList":[{"CoverageName":"","DeductibleAmount":"","NetworkTier":""}],"OutofPocketMaximumList":[{"CoverageName":"","OOPMAmount":"","NetworkTier":""}],"CostShareGroupList":[{"CostShareGroup":"","NetworkTier":"","CopayValue":""}],"LimitInformationDetail":[{"NetworkTier":"","NetworkName":"","LimitAmount":"","EnableUpdate":"False","LimitStart":"","LimitDescription":""}],"IsthisaChurchPlan":"","IsthisaCOBRAPlan":""}}'
					SET @FormInstanceId = NULL;

					INSERT INTO Fldr.Forminstance (TenantID, AddedDate, AddedBy, UpdatedDate, UpdatedBy, FolderVersionID,
												FormDesignID, FormDesignVersionID, Name, DOCID, IsActive, AnchorDocumentID)
					SELECT @TenantID AS TenantID
						, @Date AS AddedDate
						, @AddedBy AS AddedBy
						, NULL AS UpdatedDate
						, NULL AS UpdatedBy
						, @FolderVersionId AS FolderVersionID
						, @FormID_Medical AS FormDesignID
						, @FormDesignVersionID_Medical AS FormDesignVersionID
						, @PlanName AS Name
						, 0 AS DocID
						, 1 AS IsActive
						, 0 AS AnchorDocumentID

					SET @FormInstanceId = SCOPE_IDENTITY()

					UPDATE Fldr.Forminstance
					SET DOCID = @FormInstanceId
					WHERE Forminstanceid = @FormInstanceId

					UPDATE Fldr.Forminstance
					SET AnchorDocumentID = @FormInstanceId_Business
					WHERE Forminstanceid = @FormInstanceId

					INSERT INTO Fldr.FormInstanceDataMap (FormInstanceID, ObjectInstanceID, FormData, CompressJsonData)
					SELECT @FormInstanceId, 0 AS ObjectInstanceID, @FormData AS FormData, NULL AS CompressJsonData
					SET @FormData=NULL;


					----------------------------------------------------------------------------------------------------------------
					--RX
					SET @FormData ='{"SearchFields":{"ProductName":"","ProductID":"","PlanEffectiveDate":"","State":"","MarketSegment":"","LineofBusiness":"","FundingArrangement":"","Module":"","RxNetworkTierList":[{"NetworkTier":""}],"RxBenefitReviewGrid":[{"Covered":"","RxCopay":"","RxCoinsurance":"","IndividualRxDeductible":"","FamilyRxDeductible":""}],"ProductType":""}}'
					SET @FormInstanceId = NULL;

					INSERT INTO Fldr.Forminstance (TenantID, AddedDate, AddedBy, UpdatedDate, UpdatedBy, FolderVersionID,
												FormDesignID, FormDesignVersionID, Name, DOCID, IsActive, AnchorDocumentID)
					SELECT @TenantID AS TenantID
						, @Date AS AddedDate
						, @AddedBy AS AddedBy
						, NULL AS UpdatedDate
						, NULL AS UpdatedBy
						, @FolderVersionId AS FolderVersionID
						, @FormID_Rx AS FormDesignID
						, @FormDesignVersionID_Rx AS FormDesignVersionID
						, @PlanName AS Name
						, 0 AS DocID
						, 1 AS IsActive
						, 0 AS AnchorDocumentID

					SET @FormInstanceId = SCOPE_IDENTITY()

					UPDATE Fldr.Forminstance
					SET DOCID = @FormInstanceId
					WHERE Forminstanceid = @FormInstanceId

					UPDATE Fldr.Forminstance
					SET AnchorDocumentID = @FormInstanceId_Business
					WHERE Forminstanceid = @FormInstanceId


					INSERT INTO Fldr.FormInstanceDataMap (FormInstanceID, ObjectInstanceID, FormData, CompressJsonData)
					SELECT @FormInstanceId, 0 AS ObjectInstanceID, @FormData AS FormData, NULL AS CompressJsonData
					SET @FormData=NULL;


					----------------------------------------------------------------------------------------------------------------
					--Vision
					SET @FormData='{"SearchFields":{"ProductName":"","PlanEffectiveDate":"","State":"","MarketSegment":"","FundingArrangement":"","ProductID":"","Module":"","LineofBusiness":"","VisionDeductibleMaximumsList":[{"VisionNetworkTier":""}],"VisionBenefitReview":[{"VisionNetworkTier":"","CostShareType":"","Covered":"","VisionCopay":"","VisionCoinsurance":"","IndVisionDeductible":"","FamVisionDeductible":""}],"ProductType":""}}'
					SET @FormInstanceId = NULL;

					INSERT INTO Fldr.Forminstance (TenantID, AddedDate, AddedBy, UpdatedDate, UpdatedBy, FolderVersionID,
												FormDesignID, FormDesignVersionID, Name, DOCID, IsActive, AnchorDocumentID)
					SELECT @TenantID AS TenantID
						, @Date AS AddedDate
						, @AddedBy AS AddedBy
						, NULL AS UpdatedDate
						, NULL AS UpdatedBy
						, @FolderVersionId AS FolderVersionID
						, @FormID_Vision AS FormDesignID
						, @FormDesignVersionID_Vision AS FormDesignVersionID
						, @PlanName AS Name
						, 0 AS DocID
						, 1 AS IsActive
						, 0 AS AnchorDocumentID

					SET @FormInstanceId = SCOPE_IDENTITY()

					UPDATE Fldr.Forminstance
					SET DOCID = @FormInstanceId
					WHERE Forminstanceid = @FormInstanceId

					UPDATE Fldr.Forminstance
					SET AnchorDocumentID = @FormInstanceId_Business
					WHERE Forminstanceid = @FormInstanceId

					INSERT INTO Fldr.FormInstanceDataMap (FormInstanceID, ObjectInstanceID, FormData, CompressJsonData)
					SELECT @FormInstanceId, 0 AS ObjectInstanceID, @FormData AS FormData, NULL AS CompressJsonData
					SET @FormData=NULL;


					----------------------------------------------------------------------------------------------------------------
					--Dental
					SET @FormData='{"SearchFields":{"ProductId":"","ProductName":"","PlanEffectiveDate":"","LineofBusiness":"","State":"","MarketSegment":"","FundingArrangement":"","Module":"","DentalNetworkList":[{"DentalNetworkTier":""}],"DentalClassCostShare":[{"CostShareType":"","DentalCopay":"","DentalCoinsurance":""}],"DentalClassSelection":[{"DentalClass":""}],"DentalLimitsInformationDetail":[{"LimitAmount":""}],"ProductType":"","DentalBenefitReview":[{"DentalNetworkTier":"","DentalClass":"","Covered":"","DentalCopay":"","DentalCoinsurance":"","IndDentalDeductible":"","FamDentalDeductible":""}]}}'
					SET @FormInstanceId = NULL;

					INSERT INTO Fldr.Forminstance (TenantID, AddedDate, AddedBy, UpdatedDate, UpdatedBy, FolderVersionID,
												FormDesignID, FormDesignVersionID, Name, DOCID, IsActive, AnchorDocumentID)
					SELECT @TenantID AS TenantID
						, @Date AS AddedDate
						, @AddedBy AS AddedBy
						, NULL AS UpdatedDate
						, NULL AS UpdatedBy
						, @FolderVersionId AS FolderVersionID
						, @FormID_Dental AS FormDesignID
						, @FormDesignVersionID_Dental AS FormDesignVersionID
						, @PlanName AS Name
						, 0 AS DocID
						, 1 AS IsActive
						, 0 AS AnchorDocumentID

					SET @FormInstanceId = SCOPE_IDENTITY()

					UPDATE Fldr.Forminstance
					SET DOCID = @FormInstanceId
					WHERE Forminstanceid = @FormInstanceId

					UPDATE Fldr.Forminstance
					SET AnchorDocumentID = @FormInstanceId_Business
					WHERE Forminstanceid = @FormInstanceId

					INSERT INTO Fldr.FormInstanceDataMap (FormInstanceID, ObjectInstanceID, FormData, CompressJsonData)
					SELECT @FormInstanceId, 0 AS ObjectInstanceID, @FormData AS FormData, NULL AS CompressJsonData
					SET @FormData= NULL;


					----------------------------------------------------------------------------------------------------------------
					--Package
					SET @FormData='{"SearchFields":{"ProductType":"","PackageEffectiveDate":"","MedicalPlanEffectiveDate":"","RxPlanEffectiveDate":"","DentalPlanEffectiveDate":"","VisionPlanEffectiveDate":"","PackageState":"","MedicalState":"","RxState":"","DentalState":"","VisionState":"","PackageMarketSegment":"","MedicalMarketSegment":"","RxMarketSegment":"","DentalMarketSegment":"","VisionMarketSegment":"","PackageFundingArrangement":"","MedicalFundingArrangement":"","RxFundingArrangement":"","DentalFundingArrangement":"","VisionFundingArrangement":"","PackageName":"","MedicalProductName":"","RxProductName":"","DentalProductName":"","VisionProductName":"","PackageID":"","MedicalProductID":"","DentalProductID":"","RxProductID":"","VisionProductID":"","MedicalFoundationTemplate":"","MedicalTypeofPlan":"","MedicalBenefitPeriod":"","DeductibleOptions":"","MedicalOOPMOptions":"","MedicalIsthisaGrandfatheredPlan":"","Module":"","CoinsuranceList":[{"CoinsuranceAmount":"","NetworkTier":""}],"DeductibleList":[{"CoverageName":"","DeductibleAmount":"","NetworkTier":""}],"OutofPocketMaximumList":[{"CoverageName":"","OOPMAmount":"","NetworkTier":""}],"CostShareGroupList":[{"CostShareGroup":"","NetworkTier":"","CopayValue":""}],"LimitInformationDetail":[{"NetworkTier":"","NetworkName":"","LimitAmount":"","EnableUpdate":"","LimitStart":"","LimitDescription":""}],"RxNetworkTierList":[{"NetworkTier":""}],"RxBenefitReviewGrid":[{"Covered":"","RxCopay":"","RxCoinsurance":"","IndividualRxDeductible":"","FamilyRxDeductible":""}],"DentalNetworkList":[{"DentalNetworkTier":""}],"DentalClassCostShare":[{"DentalNetworkTier":"","DentalClass":"","CostShareType":"","DentalCopay":"","DentalCoinsurance":""}],"DentalBenefitReview":[{"DentalNetworkTier":"","DentalClass":"","Covered":"","DentalCopay":"","DentalCoinsurance":"","IndDentalDeductible":"","FamDentalDeductible":""}],"DentalLimitsInformationDetail":[{"LimitAmount":""}],"VisionNetworkList":[{"VisionNetworkTier":""}],"VisionBenefitReview":[{"VisionNetworkTier":"","CostShareType":"","Covered":"","VisionCopay":"","VisionCoinsurance":"","IndVisionDeductible":"","FamVisionDeductible":""}],"PackageOfferMedicalProduct":"","PackageOfferRxProduct":"","PackageOfferDentalProduct":"","PackageOfferVisionProduct":"","PackageOfferHearingProduct":"","TestProductSearchDDL":""}}'
					SET @FormInstanceId = NULL;

					INSERT INTO Fldr.Forminstance (TenantID, AddedDate, AddedBy, UpdatedDate, UpdatedBy, FolderVersionID,
												FormDesignID, FormDesignVersionID, Name, DOCID, IsActive, AnchorDocumentID)
					SELECT @TenantID AS TenantID
						, @Date AS AddedDate
						, @AddedBy AS AddedBy
						, NULL AS UpdatedDate
						, NULL AS UpdatedBy
						, @FolderVersionId AS FolderVersionID
						, @FormID_Package AS FormDesignID
						, @FormDesignVersionID_Package AS FormDesignVersionID
						, @PlanName AS Name
						, 0 AS DocID
						, 1 AS IsActive
						, 0 AS AnchorDocumentID

					SET @FormInstanceId = SCOPE_IDENTITY()

					UPDATE Fldr.Forminstance
					SET DOCID = @FormInstanceId
					WHERE Forminstanceid = @FormInstanceId

					UPDATE Fldr.Forminstance
					SET AnchorDocumentID = @FormInstanceId_Business
					WHERE Forminstanceid = @FormInstanceId

					INSERT INTO Fldr.FormInstanceDataMap (FormInstanceID, ObjectInstanceID, FormData, CompressJsonData)
					SELECT @FormInstanceId, 0 AS ObjectInstanceID, @FormData AS FormData, NULL AS CompressJsonData

					SET @FormData=null;


					----------------------------------------------------------------------------------------------------------------
					--SOB
					SET @FormData='{"CoverPage":{"ManualOverrideForScheduleofBenefits":"False","ScheduleofBenefits":""},"Introduction":{"ManualOverrideforPlanDetails":"False","PlanDetails":""},"BenefitServiceDetails":{"ManualOverrideforCoverageDetails":"False","CoverageDetails":"","ManualOverrideforCOBServices":"False","COBServices":"","ManualOverrideForAdditionalBenefitProgram":"False","AdditionalBenefitProgram":"","ManualOverrideforCoverageDetailsPrescriptionDrug":"False","CoverageDetailsPrescriptionDrug":"","ManualOverrideforPrescriptionDrug":"False","PrescriptionDrug":"","ManualOverrideforCoverageDetailsPediatricDental":"False","CoverageDetailsPediatricDental":"","ManualOverrideforPediatricDentalServices":"False","PediatricDentalServices":"","ManualOverrideforCoverageDetailsVision":"False","CoverageDetailsVision":"","ManualOverrideforVisionServices":"False","VisionServices":""},"ComplianceDetails":{"ManualOverrideForComplianceDetails":"False","ComplianceDetailsView":""},"FooterInformation":{"ManualOverrideforGroupName":"False","GroupName":"","ManualOverrideforGrandfatheredInfo":"False","GrandfatheredInfo":"","ManualOverrideforPlanType":"False","PlanType":"","ManualOverrideforEffectiveDate":"False","EffectiveDate":"","ManualOverrideforFullyFundedFooterDetails":"False","FullyFundedFooterDetails":""},"GroupInformation":{"ManualOverrideforGroupInfo":"","GroupInfo":"","ManualOverrideforSignatureInfo":"","SignatureInfo":""}}'
					SET @FormInstanceId = NULL;

					INSERT INTO Fldr.Forminstance (TenantID, AddedDate, AddedBy, UpdatedDate, UpdatedBy, FolderVersionID,
												FormDesignID, FormDesignVersionID, Name, DOCID, IsActive, AnchorDocumentID)
					SELECT @TenantID AS TenantID
						, @Date AS AddedDate
						, @AddedBy AS AddedBy
						, NULL AS UpdatedDate
						, NULL AS UpdatedBy
						, @FolderVersionId AS FolderVersionID
						, @FormID_SOB AS FormDesignID
						, @FormDesignVersionID_SOB AS FormDesignVersionID
						, @PlanName AS Name
						, 0 AS DocID
						, 1 AS IsActive
						, 0 AS AnchorDocumentID

					SET @FormInstanceId = SCOPE_IDENTITY()

					UPDATE Fldr.Forminstance
					SET DOCID = @FormInstanceId
					WHERE Forminstanceid = @FormInstanceId

					UPDATE Fldr.Forminstance
					SET AnchorDocumentID = @FormInstanceId_Business
					WHERE Forminstanceid = @FormInstanceId

					INSERT INTO Fldr.FormInstanceDataMap (FormInstanceID, ObjectInstanceID, FormData, CompressJsonData)
					SELECT @FormInstanceId, 0 AS ObjectInstanceID, @FormData AS FormData, NULL AS CompressJsonData
					SET @FormData=NULL;
					----------------------------------------------------------------------------------------------------------------
					--SBC
					SET @FormData='{"SBCPage": { "ManualOverrideforPlanName":  ""  , "PlanName":  ""  , "ManualOverrideforCoveragePeriod":  ""  , "CoveragePeriod":  ""  , "ManualOverrideforCoverageandPlanType":  ""  , "CoverageandPlanType":  ""  , "ManualOverrideforSummaryofBenifit":  ""  , "SummaryofBenefit":  ""  , "ManualOverrideforImportantQuestions":  ""  , "ImportantQuestions":  ""  , "ManualOverrideforHeaderofCommonMedicalEvent":  "False"  , "HeaderofCommonMedicalEvent":  ""  , "ManualOverrideforCommonMedicalEvent":  ""  , "CommonMedicalEvent":  ""  , "ManualOverrideForExcludedServices":  ""  , "ExcludedServices":  ""  , "ManualOverrideForOtherCoveredServices":  ""  , "OtherCoveredServices":  ""  , "ManualOverrideforYourRightsandGrievance":  ""  , "YourRightsandGrievance":  ""  , "ManualOverrideforAbouttheseCoverageExamples":  "False"  , "AbouttheseCoverageExamples":  ""  , "ManualOverrideforNoticeInformation":  ""  , "NoticeInformation":  ""  , "ManualOverrideforFooterInfo":  ""  , "FooterInfo":  ""  , "ManualOverrideforCMEFooterInformation":  ""  , "CMEFooterInformation":  "" }}'
					SET @FormInstanceId = NULL;

					INSERT INTO Fldr.Forminstance (TenantID, AddedDate, AddedBy, UpdatedDate, UpdatedBy, FolderVersionID,
												FormDesignID, FormDesignVersionID, Name, DOCID, IsActive, AnchorDocumentID)
					SELECT @TenantID AS TenantID
						, @Date AS AddedDate
						, @AddedBy AS AddedBy
						, NULL AS UpdatedDate
						, NULL AS UpdatedBy
						, @FolderVersionId AS FolderVersionID
						, @FormID_SBC AS FormDesignID
						, @FormDesignVersionID_SBC AS FormDesignVersionID
						, @PlanName AS Name
						, 0 AS DocID
						, 1 AS IsActive
						, 0 AS AnchorDocumentID

					SET @FormInstanceId = SCOPE_IDENTITY()

					UPDATE Fldr.Forminstance
					SET DOCID = @FormInstanceId
					WHERE Forminstanceid = @FormInstanceId

					UPDATE Fldr.Forminstance
					SET AnchorDocumentID = @FormInstanceId_Business
					WHERE Forminstanceid = @FormInstanceId

					INSERT INTO Fldr.FormInstanceDataMap (FormInstanceID, ObjectInstanceID, FormData, CompressJsonData)
					SELECT @FormInstanceId, 0 AS ObjectInstanceID, @FormData AS FormData, NULL AS CompressJsonData
					SET @FormData =null;
					----------------------------------------------------------------------------------------------------------------
					--Plan_and_Benefit_Template_View
					set @FormData='{"GeneralInformation":{"PlanInformation":{"HIOSIssuerID":"","IssuerState":"","MarketCoverage":"","DentalOnlyPlan":"","TIN":""}},"ProductDetails":{"PlanIdentifiers":{"PlanIdentifierList":[{"HIOSPlanIDStandardComponent":"","PlanMarketingName":"","HIOSProductID":"","HPID":"","NetworkID":"","ServiceAreaID":"","FormularyID":""}]},"PlanAttributes":{"PlanAttributesList":[{"HIOSPlanIDStandardComponent":"","PlanMarketingName":"","HIOSProductID":"","NewExistingPlan":"","PlanType":"","LevelofCoverage":"","DesignType":"","UniquePlanDesign":"","IssuerActuarialValue":"","QHPNonQHP":"","NoticePeriodforPregnancy":"","IsReferralRequiredforSpecialist":"","SpecialistsRequiringaReferral":"","PlanLevelExclusions":"","LimitedCostSharingPlanVariationEstAdvancedPayment":"","DoesthisplanofferCompositeRating":"","ChildOnlyOffering":"","ChildOnlyPlanID":"","TobaccoWellnessProgramOffered":"","DiseaseManagementProgramsOffered":"","EHBPercentofTotalPremium":""}]},"StandardAloneDentalOnly":{"StandardAloneDentalOnlyList":[{"HIOSPlanIDStandardComponent":"","PlanMarketingName":"","EHBApportionmentforPediatricDental":"","GuaranteedVsEstimatedRate":""}]},"AVCalculatorAdditionalBenefitDesign":{"AVCalculatorAdditionalBenefitDesignList":[{"HIOSPlanIDStandardComponent":"","PlanMarketingName":"","MaximumCoinsuranceforSpecialtyDrugs":"","MaximumNumberofDaysforCharginganInpatientCopay":"","BeginPrimaryCareCostSharingAfteraSetNumberofVisits":"","BeginPrimaryCareDeductibleCoinsuranceAfteraSetNumberofCopays":""}]},"PlanDates":{"PlanDatesList":[{"HIOSPlanIDStandardComponent":"","PlanMarketingName":"","PlanEffectiveDate":"","PlanExpirationDate":""}]},"GeographicCoverage":{"GeographicCoverageList":[{"HIOSPlanIDStandardComponent":"","PlanMarketingName":"","OutofCountryCoverage":"","OutofCountryCoverageDescription":"","OutofServiceAreaCoverage":"","OutofServiceAreaCoverageDescription":"","NationalNetwork":""}]},"AdditionalInformation":{"PlanLevelURLs":[{"HIOSPlanIDStandardComponent":"","PlanMarketingName":"","URLforEnrollmentPayment":""}]}},"BenefitInformation":{"BenefitList":[{"Benefits":"","EHB":"False"}],"GeneralInformation":[{"Benefits":"","IsCovered":"False","QuantitativeLimitonService":"False","LimitQuantity":"","LimitUnit":"","Exclusions":"","BenefitExplanation":"","EHBVarianceReason":"","ExcludedfromInNetworkMOOP":"False","ExcludedfromOutofNetworkMOOP":"False","EHB":"False"}]},"CostShareVariance":{"PlanCostSharingAttributes":[{"HIOSPlanIDStandardComponentVariant":"","PlanVariantMarketingName":"","LevelofCoverageMetalLevel":"","CSRVariationType":"","IssuerActuarialValue":"","AvCalculatorOutputNumber":"","MedicalAndDrugDeductiblesIntegrated":"False","MedicalAndDrugMaximumOutofPocketIntegrated":"False","MultipleInNetworkTiers":"False","FirstTierUtilization":"","SecondTierUtilization":""}]},"SBCScenario":{"PlanSBCScenarioDetailsList":[{"HIOSPlanIDStandardComponentVariant":"","PlanMarketingName":"","CSRVariationType":"","Scenario":"","PlanAndBenefitSBCScenarioList":[{"SBCScenario":"","Deductible":"","Coinsurance":"","Copayment":"","Limit":""}]}]},"Deductibles":{"DrugDeductibles":{"PlanDrugDeductibleDetails":[{"HIOSPlanIDStandardComponentVariant":"","CSRVariationType":"","PlanMarketingName":"","DeductibleDrugType":"","PlanAndBenefitsTemplateNetworkList":[{"NetworkName":"","Individual":"","Family":"","DefaultCoinsurance":""}]}]},"DeductibleSubGroup":{"PlanDeductibleSubGroupDetails":[{"HIOSPlanIDStandardComponentVariant":"","PlanMarketingName":"","CSRVariationType":"","DeductibleSubGroup":"","NetworkName":"","Individual":"","Family":""}]}},"MaximumOutofPocket":{"PlanMaximumOutofPocketDetails":[{"HIOSPlanIDStandardComponentVariant":"","PlanMarketingName":"","CSRVariationType":"","MaximumOutofPocketType":"","PlanAndBenefitsTemplateNetworkList":[{"NetworkName":"","Individual":"","Family":""}]}]},"HSAHRADetail":{"HSAHRADetailList":[{"HIOSPlanIDStandardComponentVariant":"","PlanMarketingName":"","LevelofCoverageMetalLevel":"","CSRVariationType":"","HSAEligible":"","HSAHRAEmployerContribution":"","HSAHRAEmployerContributionAmount":""}]},"PlanVariantLevelURLs":{"PlanVariantLevelURLsList":[{"HIOSPlanIDStandardComponentVariant":"","PlanMarketingName":"","LevelofCoverageMetalLevel":"","CSRVariationType":"","URLforSummaryofBenefitsCoverage":"","PlanBrochure":""}]},"PlanBenefitInformation":{"PlanBenefitDetails":[{"HIOSPlanIDStandardComponentVariant":"","PlanMarketingName":"","CSRVariationType":"","Benefit":"","BenefitsTemplateNetworkList":[{"NetworkName":"","Copay":"","Coinsurance":""}]}]}}'
					SET @FormInstanceId = NULL;

					INSERT INTO Fldr.Forminstance (TenantID, AddedDate, AddedBy, UpdatedDate, UpdatedBy, FolderVersionID,
												FormDesignID, FormDesignVersionID, Name, DOCID, IsActive, AnchorDocumentID)
					SELECT @TenantID AS TenantID
						, @Date AS AddedDate
						, @AddedBy AS AddedBy
						, NULL AS UpdatedDate
						, NULL AS UpdatedBy
						, @FolderVersionId AS FolderVersionID
						, @FormID_Plan_and_Benefit_Template_View AS FormDesignID
						, @FormDesignVersionID_Plan_and_Benefit_Template_View AS FormDesignVersionID
						, @PlanName AS Name
						, 0 AS DocID
						, 1 AS IsActive
						, 0 AS AnchorDocumentID

					SET @FormInstanceId = SCOPE_IDENTITY()

					UPDATE Fldr.Forminstance
					SET DOCID = @FormInstanceId
					WHERE Forminstanceid = @FormInstanceId

					UPDATE Fldr.Forminstance
					SET AnchorDocumentID = @FormInstanceId_Business
					WHERE Forminstanceid = @FormInstanceId

					INSERT INTO Fldr.FormInstanceDataMap (FormInstanceID, ObjectInstanceID, FormData, CompressJsonData)
					SELECT @FormInstanceId, 0 AS ObjectInstanceID, @FormData AS FormData, NULL AS CompressJsonData
					SET @FormData=null;



					----------------------------------------------------------------------------------------------------------------
					--ICIS Grid View			------------Add logic for creating View for ICIS Grid View
					set @FormData='{"Introduction": {"ManualOverrideforPlanDetails": "False","PlanDetails": ""  },"BenefitServiceDetails": {"ManualOverrideforCoverageDetails": "False","CoverageDetails": "", "ManualOverrideforCOBServices": "False","COBServices": "","ManualOverrideforGroupName": "False", "GroupName": "", "ManualOverrideforCoverageDetailsPrescriptionDrug": "", "CoverageDetailsPrescriptionDrug": "","ManualOverrideforPrescriptionDrug": "","PrescriptionDrug": ""  }}'
					SET @FormInstanceId = NULL;

					INSERT INTO Fldr.Forminstance (TenantID, AddedDate, AddedBy, UpdatedDate, UpdatedBy, FolderVersionID,
												FormDesignID, FormDesignVersionID, Name, DOCID, IsActive, AnchorDocumentID)
					SELECT @TenantID AS TenantID
						, @Date AS AddedDate
						, @AddedBy AS AddedBy
						, NULL AS UpdatedDate
						, NULL AS UpdatedBy
						, @FolderVersionId AS FolderVersionID
						, @FormID_ICIS_Grid_View AS FormDesignID
						, @FormDesignVersionID_ICIS_Grid_View AS FormDesignVersionID
						, @PlanName AS Name
						, 0 AS DocID
						, 1 AS IsActive
						, 0 AS AnchorDocumentID

					SET @FormInstanceId = SCOPE_IDENTITY()

					UPDATE Fldr.Forminstance
					SET DOCID = @FormInstanceId
					WHERE Forminstanceid = @FormInstanceId

					UPDATE Fldr.Forminstance
					SET AnchorDocumentID = @FormInstanceId_Business
					WHERE Forminstanceid = @FormInstanceId

					INSERT INTO Fldr.FormInstanceDataMap (FormInstanceID, ObjectInstanceID, FormData, CompressJsonData)
					SELECT @FormInstanceId, 0 AS ObjectInstanceID, @FormData AS FormData, NULL AS CompressJsonData

					SET @FormData=null;


					---------------------------------------------------------------------------------------------------------------
					--SBC_Calculator_View
					SET @FormData='{"CoverageExample": { "CoverageExampleDiabetic":  [{ "Sequence":  ""  , "DateofService":  ""  , "CostShareApplies":  ""  , "RxService":  ""  , "RxTierType":  ""  , "BenefitServiceCode":  ""  , "ManualOverride":  "False"  , "ProcessingRule":  ""  , "AllowedAmount":  ""  , "Copay":  ""  , "MemberCostCopay":  ""  , "Deductible":  ""  , "MemberCostDeductible":  ""  , "Coinsurance":  ""  , "MemberCostCoinsurance":  ""  , "ReferenceID":  ""  , "CoverageType":  ""  , "ICD9DiagnosisCode":  ""  , "ICD10DiagnosisCode":  ""  , "BillingCode":  ""  , "ProviderType":  ""  , "Category":  ""  , "Description":  ""  , "BenefitCategory1":  ""  , "BenefitCategory2":  ""  , "BenefitCategory3":  ""  , "RemainingDeductible":  ""  , "OOPM":  ""  , "RemainingOOPM":  ""  }]  , "CoverageExampleFracture":  [{ "Sequence":  ""  , "DateofService":  ""  , "CostShareApplies":  ""  , "RxService":  ""  , "RxTierType":  ""  , "BenefitServiceCode":  ""  , "ManualOverride":  ""  , "ProcessingRule":  ""  , "AllowedAmount":  ""  , "Copay":  ""  , "MemberCostCopay":  ""  , "Deductible":  ""  , "MemberCostDeductible":  ""  , "Coinsurance":  ""  , "MemberCostCoinsurance":  ""  , "RemainingDeductible":  ""  , "ReferenceID":  ""  , "CoverageType":  ""  , "ICD9DiagnosisCode":  ""  , "ICD10DiagnosisCode":  ""  , "BillingCode":  ""  , "ProviderType":  ""  , "Category":  ""  , "Description":  ""  , "BenefitCategory1":  ""  , "BenefitCategory2":  ""  , "BenefitCategory3":  ""  , "OOPM":  ""  , "RemainingOOPM":  ""  }]  , "CoverageExampleMaternity":  [{ "Sequence":  ""  , "DateofService":  ""  , "CostShareApplies":  ""  , "RxService":  ""  , "RxTierType":  ""  , "BenefitServiceCode":  ""  , "ManualOverride":  ""  , "ProcessingRule":  ""  , "AllowedAmount":  ""  , "Copay":  ""  , "MemberCostCopay":  ""  , "Deductible":  ""  , "MemberCostDeductible":  ""  , "Coinsurance":  ""  , "MemberCostCoinsurance":  ""  , "RemainingDeductible":  ""  , "ReferenceID":  ""  , "CoverageType":  ""  , "ICD9DiagnosisCode":  ""  , "ICD10DiagnosisCode":  ""  , "BillingCode":  ""  , "ProviderType":  ""  , "Category":  ""  , "Description":  ""  , "BenefitCategory1":  ""  , "BenefitCategory2":  ""  , "BenefitCategory3":  ""  , "OOPM":  ""  , "RemainingOOPM":  ""  }] },"CalculatedData": { "CalculatedDataList":  [{ "TreatmentType":  ""  , "TotalCopayMemberCost":  ""  , "RoundOffCopay":  ""  , "TotalCoinsuranceMemberCost":  ""  , "RoundOffCoinsurance":  ""  , "TotalDeductibleMemberCost":  ""  , "RoundOffDeductible":  ""  , "OverallDeductible":  ""  , "SpecialistCopay":  ""  , "HospitalCopay":  ""  , "OtherCopay":  ""  , "TotalMemberCost":  ""  , "FinalMemberCost":  ""  , "RoundOffLimits":  ""  }] },"REPORTDATALanguageAssociation": { "ImportantQuestion4DeductibleServices":  [{ "ServiceIndex":  ""  , "BenefitServiceCode":  ""  , "Language":  ""  }] }}'
					SET @FormInstanceId = NULL;

					INSERT INTO Fldr.Forminstance (TenantID, AddedDate, AddedBy, UpdatedDate, UpdatedBy, FolderVersionID,
												FormDesignID, FormDesignVersionID, Name, DOCID, IsActive, AnchorDocumentID)
					SELECT @TenantID AS TenantID
						, @Date AS AddedDate
						, @AddedBy AS AddedBy
						, NULL AS UpdatedDate
						, NULL AS UpdatedBy
						, @FolderVersionId AS FolderVersionID
						, @FormID_SBC_Calculator_View AS FormDesignID
						, @FormDesignVersionID_SBC_Calculator_View AS FormDesignVersionID
						, @PlanName AS Name
						, 0 AS DocID
						, 1 AS IsActive
						, 0 AS AnchorDocumentID

					SET @FormInstanceId = SCOPE_IDENTITY()

					UPDATE Fldr.Forminstance
					SET DOCID = @FormInstanceId
					WHERE Forminstanceid = @FormInstanceId

					UPDATE Fldr.Forminstance
					SET AnchorDocumentID = @FormInstanceId_Business
					WHERE Forminstanceid = @FormInstanceId

					INSERT INTO Fldr.FormInstanceDataMap (FormInstanceID, ObjectInstanceID, FormData, CompressJsonData)
					SELECT @FormInstanceId, 0 AS ObjectInstanceID, @FormData AS FormData, NULL AS CompressJsonData

					DELETE FROM @PlanList WHERE PlanName = @PlanName;
				END

				ALTER TABLE [Fldr].[FormInstance] ENABLE TRIGGER [DML_Trgr_FormInstance]
				ALTER TABLE [Fldr].[FormInstanceDataMap] ENABLE TRIGGER [DML_Trgr_FormInstanceDataMap]

				COMMIT TRANSACTION

				SET @Comment = 'Folder create succesfully.'

				-- Surface success where the app can show it: #PackageFolderMetaProcessing holds
				-- exactly one row (this package) at this point in the outer per-package loop.
				UPDATE d
				SET d.RowStatus    = 'Valid',
				    d.ErrorMessage = 'Shell created sucessfully '
				FROM AutoMig.AutoShellRunDetails d
				JOIN #PackageFolderMetaProcessing t ON d.DetailID = t.DetailID

			END TRY

			BEGIN CATCH
				ROLLBACK TRANSACTION

				-- Safe even when the triggers were never disabled for this package (ENABLE on an
				-- already-enabled trigger is a no-op) - guards against the error happening between
				-- DISABLE and ENABLE above.
				ALTER TABLE [Fldr].[FormInstance] ENABLE TRIGGER [DML_Trgr_FormInstance]
				ALTER TABLE [Fldr].[FormInstanceDataMap] ENABLE TRIGGER [DML_Trgr_FormInstanceDataMap]

				SELECT ERROR_NUMBER() AS ErrorNumber
					, ERROR_SEVERITY() AS ErrorSeverity
					, ERROR_STATE() AS ErrorState
					, ERROR_PROCEDURE() AS ErrorProcedure
					, ERROR_LINE() AS ErrorLine
					, ERROR_MESSAGE() AS ErrorMessage;

				SET @Comment = 'Error. Error Message ' + ERROR_MESSAGE() + ' at line no. ' + CAST(ERROR_NUMBER() as varchar(10));

				-- Surface the failure where the app can show it: #PackageFolderMetaProcessing holds
				-- exactly one row (this package) at this point in the outer per-package loop.
				UPDATE d
				SET d.RowStatus    = 'CreationFailed',
				    d.ErrorMessage = 'Shell creation failed: ' + ERROR_MESSAGE()
				FROM AutoMig.AutoShellRunDetails d
				JOIN #PackageFolderMetaProcessing t ON d.DetailID = t.DetailID
			END CATCH

			UPDATE @FoldeAndFTList SET IsProcessed = 1 WHERE Id = @Id;
		END

	-------------************************************* 003.CreatePackageFolderAndPlans_WIth All_views : Finish **********************************************--------------------

	-------------************************************* 004.PackageselectionAndQHP : Start **********************************************--------------------
		-- Populate the PackageSelection and QHPDetails JSON sections on each created package instance.

		DROP TABLE IF EXISTS #PackageSelectList;
		DROP TABLE IF EXISTS #PackageInstanceList;


		SELECT distinct F.FolderID, F.Name AS FolderName, FV.FolderVersionID ,CAST(0 AS BIT) IsProcessed , CAST('' as NVARCHAR(MAX))  AS Comments
		INTO  #PackageSelectList
		FROM Fldr.Folder F
			   INNER JOIN Fldr.FolderVersion FV on F.FolderID = FV.FolderID
			   INNER JOIN Migration.packageListToBeMigrate_SG T ON F.Name = T.FolderName
		WHERE F.[Name] in (Select [ebs_Package_Folder_Name] from #PackageSelectionProcessing)
			   AND f.IsPortfolio = 1 AND F.IsPackage = 1
		ORDER BY F.FolderID DESC


		--Table for to get respected data of associated bundle
		Drop table if exists  #instanceList_Medical --for xml path
       ;with CTE as (
       Select DISTINCT fi.FormInstanceID,fi.Name,fidm.FormData,'Medical' Producttype
                    from fldr.folder f
                    inner join fldr.folderversion fv on f.FolderID=fv.FolderID
                    inner join fldr.forminstance fi on fi.FolderVersionID=fv.FolderVersionID
                    inner join fldr.FormInstanceDataMap fidm on fi.FormInstanceID=fidm.FormInstanceID
                    -- FIX: folder must be the Medical component folder (was joined to the package folder name)
                    inner join #PackageSelectionProcessing P on fi.Name=P.eBS_Medical_COMPONENT and f.[Name]=P.eBS_Medical_COMPONENT
                    where fi.FormDesignID=2405 and IsPortfolio=1 and FolderType = 1
					and fv.FolderVersionID in (Select max(folderversionid) from fldr.FolderVersion group by FolderID)
                    union
                    Select fi.FormInstanceID,fi.Name,fidm.FormData, 'Dental' Producttype
                    from fldr.folder f
                    inner join fldr.folderversion fv on f.FolderID=fv.FolderID
                    inner join fldr.forminstance fi on fi.FolderVersionID=fv.FolderVersionID
                    inner join fldr.FormInstanceDataMap fidm on fi.FormInstanceID=fidm.FormInstanceID
                    inner join #PackageSelectionProcessing P on  fi.Name=P.eBS_Dental_COMPONENT and f.[Name]=p.eBS_Dental_COMPONENT
                    where fi.FormDesignID=2405  and IsPortfolio=1 and fv.FolderVersionID in (Select max(folderversionid) from fldr.FolderVersion group by FolderID)
					and FolderType = 1
                    Union
                    Select DISTINCT fi.FormInstanceID,fi.Name,fidm.FormData , 'RX' Producttype
                    from fldr.folder f
                    inner join fldr.folderversion fv on f.FolderID=fv.FolderID
                    inner join fldr.forminstance fi on fi.FolderVersionID=fv.FolderVersionID
                    inner join fldr.FormInstanceDataMap fidm on fi.FormInstanceID=fidm.FormInstanceID
                    inner join #PackageSelectionProcessing P on  fi.Name=P.eBS_RX_COMPONENT  and f.[Name]=p.eBS_RX_COMPONENT
                    where fi.FormDesignID=2405  and IsPortfolio=1 And fi.IsActive=1
					and  fv.FolderVersionID in (Select max(folderversionid) from fldr.FolderVersion group by FolderID)
					and FolderType = 1
                    union
                    Select fi.FormInstanceID,fi.Name,fidm.FormData, 'Vision' Producttype
                    from fldr.folder f
                    inner join fldr.folderversion fv on f.FolderID=fv.FolderID
                    inner join fldr.forminstance fi on fi.FolderVersionID=fv.FolderVersionID
                    inner join fldr.FormInstanceDataMap fidm on fi.FormInstanceID=fidm.FormInstanceID
                    inner join #PackageSelectionProcessing P on  fi.Name=P.eBS_Vision_COMPONENT and f.[Name]=p.eBS_Vision_COMPONENT
                    where fi.FormDesignID=2405  and IsPortfolio=1 and  fv.FolderVersionID in (Select max(folderversionid) from fldr.FolderVersion group by FolderID)
					and FolderType = 1
                    )
                    Select * into #instanceList_Medical from CTE

		DECLARE @Comments NVARCHAR(MAX);
		Declare @SourceFormInstanceID	int
		Declare @SourceDocID				int
		Declare @SourceFolderVersionID	int
		Declare @SourceFolderID			int
		Declare @CreatedDate				datetime  = getdate()
		Declare @UpdatedDate				datetime = null
		Declare @CreatedBy				nvarchar(max) ='Superuser'
		Declare @UpdatedBy				nvarchar(max)
		Declare @TargetDocID				int
		Declare @TargetFolderversionID		int
		Declare @TargetFolderID				int
		Declare @TargetFormInstanceID  int
		DECLARE @Forminstancemaptypeidmedical Int;
		Declare @forminstancemaptypeidrx INT ;
		Declare @forminstancemaptypeiddental INT ;
		Declare @forminstancemaptypeidvision INT ;
		Declare @PkgFolderName nvarchar(max)

		SELECT @Forminstancemaptypeidmedical=forminstancemaptypeid from fldr.FormInstanceMapType where FormInstanceMapType='Medical'  -- NC Customization SatyajeetP/MaheshP

		SELECT @forminstancemaptypeidrx=forminstancemaptypeid from fldr.FormInstanceMapType where FormInstanceMapType='Rx'    -- NC Customization SatyajeetP/MaheshP

		SELECT @forminstancemaptypeiddental=forminstancemaptypeid from fldr.FormInstanceMapType where FormInstanceMapType='Dental'  --Rohit

		SELECT @forminstancemaptypeidvision=forminstancemaptypeid from fldr.FormInstanceMapType where FormInstanceMapType='Vision'   --Rohit

		WHILE EXISTS (SELECT 1 FROM #PackageSelectList WHERE IsProcessed = 0)
		BEGIN
			SET @FolderID = NULL;
			SET @FolderVersionID = NULL;

			SELECT TOP 1 @FolderID = FolderID, @FolderVersionID = FolderVersionID, @PkgFolderName = FolderName FROM #PackageSelectList WHERE IsProcessed = 0;

			DROP TABLE IF EXISTS #PackageInstanceList

			SELECT DISTINCT FormInstanceID,[Name] AS PlanName, CAST(0 AS BIT) AS IsProcessed INTO #PackageInstanceList
			FROM Fldr.FormInstance I (NOLOCK) WHERE FolderVersionID = @FolderVersionID AND FormDesignID = 2405;

			DECLARE @FormDataToMerge NVARCHAR(MAX);
			DECLARE @Original_FormData NVARCHAR(MAX);
			DECLARE @Section_FormData NVARCHAR(MAX);
			Declare @medical_formdata	Nvarchar(max);
			Declare @OfferMedicalProduct		Nvarchar(max);
			Declare @OfferRxProduct				Nvarchar(max);
			Declare @OfferDentalProduct			Nvarchar(max);
			Declare @OfferVisionProduct			Nvarchar(max);
			Declare @OfferHearingProduct		Nvarchar(max);
			SET @OfferMedicalProduct='true';
			SET @OfferRxProduct	='true';
			SET @OfferDentalProduct='true';
			SET @OfferVisionProduct	='true';



			BEGIN TRY
				WHILE EXISTS (SELECT 1 FROM #PackageInstanceList WHERE IsProcessed = 0)
				BEGIN
					-- FIX: these are created with SELECT ... INTO per instance, so drop them every iteration
					-- (previously only dropped once per package folder, which failed on a 2nd instance).
					DROP TABLE IF EXISTS #PackageSelectionBasic;
					DROP TABLE IF EXISTS #BundledProducts;
					DROP TABLE IF EXISTS #IntegratedQuestions;
					DROP TABLE IF EXISTS #MedicalProductSelection;
					DROP TABLE IF EXISTS #RxProductSelection;
					DROP TABLE IF EXISTS #DentalProductSelection;
					DROP TABLE IF EXISTS #VisionProductSelection;
					DROP TABLE IF EXISTS #PackageSelectionBundleProducts;
					DROP TABLE IF EXISTS #PackageSelectionIntegrated;
					DROP TABLE IF EXISTS #PackageSelectionMedicalProduct;
					DROP TABLE IF EXISTS #PackageSelectionRxProduct;
					DROP TABLE IF EXISTS #PackageSelectionDentalProduct;
					DROP TABLE IF EXISTS #PackageSelectionVisionProduct;
					DROP TABLE IF EXISTS #PackageSelectionHearingProduct;

					SET @FormInstanceID = NULL;
					SET @PlanName = NULL;
					SELECT TOP 1 @FormInstanceID = FormInstanceID, @PlanName = PlanName FROM #PackageInstanceList WHERE IsProcessed = 0;

					SELECT @FormData = FormData FROM Fldr.FormInstanceDataMap D (NOLOCK) WHERE FormInstanceID = @FormInstanceID;
					SET @Original_FormData = @FormData;
					--added for composite
					Select top 1 @targetFormInstanceID	=fi.FormInstanceID,
							@targetDocID			=fi.DOCID,
							@targetFolderVersionID	= fv.FolderVersionID,
							@targetFolderID			=f.folderid,
							@FormInstanceMapTypeID	=fi.FormInstanceMapTypeId
					from fldr.folder f
						inner join fldr.folderversion fv on f.folderid=fv.FolderID
						inner join fldr.forminstance fi on fv.FolderVersionID=fi.FolderVersionID and fi.FormDesignID=2405 and fi.FormInstanceID=@FormInstanceID
						inner join #PackageFolderMetaProcessing p on f.Name=P.[Package_Folder_Name] and p.Package_Name=@PlanName

					-- Build the PackageSelection JSON section (basic package info, bundled-product flags,
					-- integration questions, and per-product selection sub-sections) from the Stage 3 tables.
					IF ISJSON(@FormData) = 1
					BEGIN
						--------------------------------------------------------------------------------
						--$.PackageSelection
						SET @Section_FormData = JSON_QUERY(@FormData,'$.PackageSelection');

						SELECT @FormInstanceID AS FormInstanceID,@PlanName AS PackageName,*
						INTO #PackageSelectionBasic
						FROM OPENJSON(@Section_FormData) WITH (
							DoesthisBasePlanPackageGenerateMonthlyTemplates NVARCHAR(MAX),
							SubMarket					NVARCHAR(MAX),
							PackageID					NVARCHAR(MAX),
							PackageEffectiveDate		NVARCHAR(MAX),
							PackageExpirationDate		NVARCHAR(MAX),
							MarketSegment				NVARCHAR(MAX),
							FundingArrangement			NVARCHAR(MAX),
							[State]						NVARCHAR(MAX),
							Region						NVARCHAR(MAX),
							EnableQHP					NVARCHAR(MAX))

						UPDATE T
						SET
						T.DoesthisBasePlanPackageGenerateMonthlyTemplates = CASE WHEN D.Market_Segment = 'Small Group' THEN 'Yes' ELSE 'No' END,
						T.SubMarket = CASE WHEN D.Market_Segment IN ('Small Group','Individual') THEN 'ACA' ELSE '' END,
						T.PackageID =ISNULL(D.Package_Name,''),  ---customization as per the client mahesh P
						T.PackageEffectiveDate = CASE WHEN ISNULL(D.Package_Effective_Date,'') <> '' THEN ISNULL(CONVERT(NVARCHAR(10),CAST(D.Package_Effective_Date as date) ,101),'') ELSE '' END,
							T.PackageExpirationDate =CASE WHEN ISNULL(P.Package_Expiration_Date,'') <> '' THEN ISNULL(CONVERT(NVARCHAR(10),CAST(P.Package_Expiration_Date as date) ,101),'') ELSE '' END,
							T.MarketSegment  =		 isnull(D.Market_Segment,''),
							T.FundingArrangement =	 isnull(D.Funding_Arrangement,''),
							T.[State] =				 isnull(D.[State],'') ,
							T.Region =				 isnull(D.[Region],''),
							T.EnableQHP =			 'Yes'
						FROM #PackageSelectionBasic T
						INNER JOIN #PackageFolderMetaProcessing D ON T.PackageName = D.Package_Name
						INNER JOIN #PackageSelectionProcessing P ON T.PackageName = P.eBS_PACKAGE_NAME

						SET @Section_FormData = null;

						SET @Section_FormData = JSON_QUERY(@FormData,'$.PackageSelection.BundledProducts');

						SELECT @FormInstanceID AS FormInstanceID,@PlanName AS PackageName,*
						INTO #BundledProducts
						FROM OPENJSON(@Section_FormData) WITH (
							OfferMedicalProduct NVARCHAR(MAX),
							OfferRxProduct		NVARCHAR(MAX),
							OfferDentalProduct	NVARCHAR(MAX),
							OfferVisionProduct	NVARCHAR(MAX),
							OfferHearingProduct	NVARCHAR(MAX))

						SET @Section_FormData = null;
						SET @Section_FormData = JSON_QUERY(@FormData,'$.PackageSelection.IntegratedQuestions');

						SELECT @FormInstanceID AS FormInstanceID,@PlanName AS PackageName, *
						INTO #IntegratedQuestions
						FROM OPENJSON(@Section_FormData) WITH (
							AretheMedicalandDrugDeductibleIntegrated		NVARCHAR(MAX),
							AretheMedicalandDrugOOPMIntegrated				NVARCHAR(MAX),
							AretheMedicalandDrugTMOOPIntegrated				NVARCHAR(MAX),
							AretheMedicalandDentalDeductibleIntegrated		NVARCHAR(MAX),
							AretheMedicalandDentalOOPMIntegrated			NVARCHAR(MAX),
							AretheMedicalandVisionDeductibleIntegrated		NVARCHAR(MAX),
							AretheMedicalandVisionOOPMIntegrated			NVARCHAR(MAX))

						SET @Section_FormData = null;
						SET @Section_FormData = JSON_QUERY(@FormData,'$.PackageSelection.MedicalProductSelection');

						SELECT @FormInstanceID AS FormInstanceID,@PlanName AS PackageName,*
						INTO #MedicalProductSelection
						FROM OPENJSON(@Section_FormData) WITH (
							SelectMedicalProduct		NVARCHAR(MAX),
							ProductID					NVARCHAR(MAX),
							FolderName					NVARCHAR(MAX),
							[Version]					NVARCHAR(MAX),
							EffectiveDate				NVARCHAR(MAX)
						)

						SET @Section_FormData = null;
						SET @Section_FormData = JSON_QUERY(@FormData,'$.PackageSelection.RxProductSelection');

						SELECT @FormInstanceID AS FormInstanceID,@PlanName AS PackageName,*
						INTO #RxProductSelection
						FROM OPENJSON(@Section_FormData) WITH (
							SelectRxProduct		NVARCHAR(MAX),
							ProductID			NVARCHAR(MAX),
							FolderName			NVARCHAR(MAX),
							[Version]			NVARCHAR(MAX),
							EffectiveDate		NVARCHAR(MAX)
						)

						SET @Section_FormData = null;
						SET @Section_FormData = JSON_QUERY(@FormData,'$.PackageSelection.DentalProductSelection');

						SELECT @FormInstanceID AS FormInstanceID,@PlanName AS PackageName,*
						INTO #DentalProductSelection
						FROM OPENJSON(@Section_FormData) WITH (
							SelectDentalProduct	NVARCHAR(MAX),
							ProductID			NVARCHAR(MAX),
							FolderName			NVARCHAR(MAX),
							[Version]			NVARCHAR(MAX),
							EffectiveDate		NVARCHAR(MAX)
						)

						SET @Section_FormData = null;
						SET @Section_FormData = JSON_QUERY(@FormData,'$.PackageSelection.VisionProductSelection');

						SELECT @FormInstanceID AS FormInstanceID,@PlanName AS PackageName,*
						INTO #VisionProductSelection
						FROM OPENJSON(@Section_FormData) WITH (
							SelectDentalProduct	NVARCHAR(MAX),
							ProductID			NVARCHAR(MAX),
							FolderName			NVARCHAR(MAX),
							[Version]			NVARCHAR(MAX),
							EffectiveDate		NVARCHAR(MAX)
						)

						SET @Section_FormData
							= JSON_QUERY((SELECT((
								SELECT DISTINCT  DoesthisBasePlanPackageGenerateMonthlyTemplates,SubMarket,PackageName,PackageID,PackageEffectiveDate,PackageExpirationDate,MarketSegment,FundingArrangement,[State],Region,EnableQHP,
									JSON_QUERY(REPLACE(REPLACE((select * from #BundledProducts for json path),']',''),'[','')   )			AS BundledProducts,
									JSON_QUERY(REPLACE(REPLACE((select * from #IntegratedQuestions for json path),']',''),'[','')   )		AS IntegratedQuestions,
									JSON_QUERY(REPLACE(REPLACE((select * from #MedicalProductSelection for json path),']',''),'[','')   )	AS MedicalProductSelection,
									JSON_QUERY(REPLACE(REPLACE((select * from #RxProductSelection for json path),']',''),'[','')   )			AS RxProductSelection,
									JSON_QUERY(REPLACE(REPLACE((select * from #DentalProductSelection for json path),']',''),'[','')   )		AS DentalProductSelection,
									JSON_QUERY(REPLACE(REPLACE((select * from #VisionProductSelection for json path),']',''),'[','')   )		AS VisionProductSelection
							FROM #PackageSelectionBasic FOR JSON PATH
						))))


						SET @Section_FormData = REPLACE(@Section_FormData, '[','');
						SET @Section_FormData = REPLACE(@Section_FormData, ']','');
						SET @FormData = JSON_MODIFY(@FormData,'$.PackageSelection',JSON_QUERY(@Section_FormData));
						SET @Section_FormData = NULL;


---------------------------------------------------------------------------------------------------------------------------

				-- For each offered product (Medical, Rx, Dental, Vision, Hearing), pull the linked component's
				-- full JSON form data into this package instance and record the composite form-instance mapping.
				SET @Section_FormData = JSON_QUERY(@FormData,'$.PackageSelection.BundledProducts');


				SELECT @FormInstanceID AS FormInstanceID,@PlanName AS PackageName,*
				INTO #PackageSelectionBundleProducts
				FROM OPENJSON(@Section_FormData) WITH (
					OfferMedicalProduct			NVARCHAR(MAX),
					OfferRxProduct				NVARCHAR(MAX),
					OfferDentalProduct			NVARCHAR(MAX),
					OfferVisionProduct			NVARCHAR(MAX),
					OfferHearingProduct			NVARCHAR(MAX)
				)

				UPDATE T
					SET T.OfferMedicalProduct = ISNULL(D.Offer_Medical_Product,''),
						T.OfferRxProduct =		ISNULL(D.Offer_Rx_Product,''),
						T.OfferDentalProduct  = ISNULL(D.Offer_Dental_Product,''),
						T.OfferVisionProduct =  ISNULL(D.Offer_Vision_Product,'')
			FROM #PackageSelectionBundleProducts T INNER JOIN #PackageFolderMetaProcessing D ON T.PackageName = D.Package_Name

				--Assigning to variable so that we can use them for populating below bundles
				Select top 1 @OfferMedicalProduct	= D.Offer_Medical_Product,
							@OfferRxProduct			= D.Offer_Rx_Product,
							@OfferDentalProduct		= D.Offer_Dental_Product,
							@OfferVisionProduct		= D.Offer_Vision_Product
					  FROM #PackageSelectionBundleProducts T
						INNER JOIN #PackageFolderMetaProcessing D ON T.PackageName = D.Package_Name

				-- FIX: the sheet value is Yes/No (or Y/N, 1/0, true/false), but the checks below compare to 'true'.
				-- Normalise so "Yes" actually merges the component data and creates the CompositeFormInstanceMap row.
				SET @OfferMedicalProduct = CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(@OfferMedicalProduct,'')))) IN ('yes','y','true','1') THEN 'true' ELSE 'false' END;
				SET @OfferRxProduct      = CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(@OfferRxProduct,''))))      IN ('yes','y','true','1') THEN 'true' ELSE 'false' END;
				SET @OfferDentalProduct  = CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(@OfferDentalProduct,''))))  IN ('yes','y','true','1') THEN 'true' ELSE 'false' END;
				SET @OfferVisionProduct  = CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(@OfferVisionProduct,''))))  IN ('yes','y','true','1') THEN 'true' ELSE 'false' END;

				SET @Section_FormData = NULL;

				SET @Section_FormData
									= JSON_QUERY((SELECT((
										SELECT DISTINCT  OfferMedicalProduct,OfferRxProduct,OfferDentalProduct,OfferVisionProduct
											FROM #PackageSelectionBundleProducts FOR JSON PATH
										))))

				SET @Section_FormData = REPLACE(@Section_FormData, '[','');
				SET @Section_FormData = REPLACE(@Section_FormData, ']','');
				-- BundledProducts is intentionally not written back (left as the template defaults), as before.

				SET @Section_FormData = NULL;


----------------------------------------------------------------------------------------------------------------------------------------
				-- IntegratedQuestions update was commented out in the original (data not present in the sheet); removed.
					-------------------------------------------------------------------------------------
					--------------------------------------------------------------------------------


						SET @Section_FormData = JSON_QUERY(@FormData,'$.PackageSelection.MedicalProductSelection');

						SELECT @FormInstanceID AS FormInstanceID,@PlanName AS PackageName,*
						INTO #PackageSelectionMedicalProduct
						FROM OPENJSON(@Section_FormData) WITH (
							SelectMedicalProduct		NVARCHAR(MAX),
							FolderName					NVARCHAR(MAX),
							[Version]					NVARCHAR(MAX),
							EffectiveDate				NVARCHAR(MAX)
						)

						UPDATE T
							SET T.SelectMedicalProduct		= isnull(D.eBS_Medical_COMPONENT,''),
								T.FolderName				= isnull(D.eBS_Medical_COMPONENT,''),
								T.[Version]					= isnull(D.Medical_Version,''),
								T.EffectiveDate				= D.Medical_Effective_Date

						FROM #PackageSelectionMedicalProduct T INNER JOIN #PackageSelectionProcessing D ON T.PackageName = D.ebs_Package_Name

						SET @Section_FormData = NULL;

						SET @Section_FormData  = JSON_QUERY((SELECT((
												SELECT DISTINCT SelectMedicalProduct,FolderName,[Version],EffectiveDate
													FROM #PackageSelectionMedicalProduct FOR JSON PATH
												))))

						SET @Section_FormData = REPLACE(@Section_FormData, '[','');
						SET @Section_FormData = REPLACE(@Section_FormData, ']','');

						SET @medical_formdata = NULL;
						Select @medical_formdata= formdata from #instanceList_Medical I
						inner join #PackageSelectionMedicalProduct P
						on P.SelectMedicalProduct=I.Name and I.Producttype='Medical'


						-- FIX: also require the component form data to exist, otherwise JSON_MODIFY(..., NULL) deletes the template sections
						if (@OfferMedicalProduct = 'true' AND @medical_formdata IS NOT NULL)
						begin
							SET @FormData = JSON_MODIFY(@FormData,'$.ProductRules',JSON_QUERY(@medical_formdata,'$.ProductRules'));
							SET @FormData = JSON_MODIFY(@FormData,'$.GeneralCostShare',JSON_QUERY(@medical_formdata,'$.GeneralCostShare'));
							SET @FormData = JSON_MODIFY(@FormData,'$.Network',JSON_QUERY(@medical_formdata,'$.Network'));
							SET @FormData = JSON_MODIFY(@FormData,'$.BenefitReview',JSON_QUERY(@medical_formdata,'$.BenefitReview'));
							SET @FormData = JSON_MODIFY(@FormData,'$.Limits',JSON_QUERY(@medical_formdata,'$.Limits'));
							SET @FormData = JSON_MODIFY(@FormData,'$.CascadingCostShare',JSON_QUERY(@medical_formdata,'$.CascadingCostShare'));
							SET @FormData = JSON_MODIFY(@FormData,'$.StandardServices',JSON_QUERY(@medical_formdata,'$.StandardServices'));
							SET @FormData = JSON_MODIFY(@FormData,'$.AdditionalServices',JSON_QUERY(@medical_formdata,'$.AdditionalServices'));
							SET @FormData = JSON_MODIFY(@FormData,'$.SlidingCostShare',JSON_QUERY(@medical_formdata,'$.SlidingCostShare'));
							SET @FormData = JSON_MODIFY(@FormData,'$.BenefitReviewGuardrail',JSON_QUERY(@medical_formdata,'$.BenefitReviewGuardrail'));
							SET @FormData = JSON_MODIFY(@FormData,'$.CombinedCostShare',JSON_QUERY(@medical_formdata,'$.CombinedCostShare'));

							-- CompositeFormInstanceMap Table  entry

							Set @sourceDocID =Null
							Set @sourceFolderversionID =Null
							Set @sourceFolderID =Null
							Set @sourceFormInstanceID =Null

							Select top 1 @sourceDocID	=fi.docid		,
						   @sourceFolderversionID=fv.FolderVersionID	,
						   @sourceFolderID=f.folderid,
						   @sourceFormInstanceID=fi.forminstanceid  from fldr.folder f
								inner join fldr.folderversion fv on f.folderid=fv.FolderID
								inner join fldr.forminstance fi on fv.FolderVersionID=fi.FolderVersionID and fi.FormDesignID=2405
								inner join #PackageSelectionProcessing p on f.Name=P.eBS_Medical_COMPONENT	and fi.name=eBS_Medical_COMPONENT
								and P.eBS_PACKAGE_NAME=@PlanName
							order by fv.FolderVersionID desc

							if (@sourceDocID is not null and @sourceFolderversionID is not null And @sourceFolderID is not null and @sourceFormInstanceID is not null )
							Begin
								Insert into fldr.CompositeFormInstanceMap(SourceFormInstanceID
														,SourceDocID
														,SourceFolderVersionID
														,SourceFolderID
														,TargetFormInstanceID
														,TargetDocID
														,TargetFolderversionID
														,TargetFolderID
														,FormInstanceMapTypeID
														,CreatedDate
														,UpdatedDate
														,CreatedBy
														,UpdatedBy)
								Select @SourceFormInstanceID ,
												   @SourceDocID			 ,
												   @SourceFolderVersionID,
												   @SourceFolderID		 ,
												   @TargetFormInstanceID,
												   @TargetDocID,
												   @TargetFolderversionID,
												   @TargetFolderID,
												   @Forminstancemaptypeidmedical,
												   @CreatedDate,
												   @UpdatedDate,
												   @CreatedBy,
												   @UpdatedBy

							end
						END
						SET @FormData = JSON_MODIFY(@FormData,'$.PackageSelection.MedicalProductSelection',JSON_QUERY(@Section_FormData));


						SET @Section_FormData = NULL;
					-------------------------------------------------------------------------------------
					--------------------------------------------------------------------------------


						SET @Section_FormData = JSON_QUERY(@FormData,'$.PackageSelection.RxProductSelection');

						SELECT @FormInstanceID AS FormInstanceID,@PlanName AS PackageName,*
						INTO #PackageSelectionRxProduct
						FROM OPENJSON(@Section_FormData) WITH (
							SelectRxProduct		NVARCHAR(MAX),
							FolderName					NVARCHAR(MAX),
							[Version]						NVARCHAR(MAX),
							EffectiveDate				NVARCHAR(MAX)
						)

						UPDATE T
						SET T.SelectRxProduct = isnull(D.eBS_RX_COMPONENT,''),
						T.FolderName=isnull(D.eBS_RX_COMPONENT,''),
							T.[Version] = isnull(D.Rx_Version,''),
						T.EffectiveDate=D.Rx_Effective_Date
						FROM #PackageSelectionRxProduct T
							INNER JOIN #PackageSelectionProcessing D ON T.PackageName = D.eBS_PACKAGE_NAME


						SET @Section_FormData = NULL;

						SET @Section_FormData
											= JSON_QUERY((SELECT((
												SELECT DISTINCT SelectRxProduct,FolderName,[Version],EffectiveDate
													FROM #PackageSelectionRxProduct FOR JSON PATH
												))))

						Set @medical_formdata = NULL;
						Select @medical_formdata= formdata from #instanceList_Medical I inner join #PackageSelectionRxProduct P on P.SelectRxProduct=I.Name  and I.Producttype='RX'


						SET @Section_FormData = REPLACE(@Section_FormData, '[','');
						SET @Section_FormData = REPLACE(@Section_FormData, ']','');

						if (@OfferRxProduct = 'true' AND @medical_formdata IS NOT NULL)
						begin
							SET @FormData = JSON_MODIFY(@FormData,'$.RxProductRules',JSON_QUERY(@medical_formdata,'$.RxProductRules'));
							SET @FormData = JSON_MODIFY(@FormData,'$.RxGeneralCostShare',JSON_QUERY(@medical_formdata,'$.RxGeneralCostShare'));
							SET @FormData = JSON_MODIFY(@FormData,'$.RxBenefitReview',JSON_QUERY(@medical_formdata,'$.RxBenefitReview'));
							SET @FormData = JSON_MODIFY(@FormData,'$.RxNetworkandTierSelection',JSON_QUERY(@medical_formdata,'$.RxNetworkandTierSelection'));
							SET @FormData = JSON_MODIFY(@FormData,'$.RxNetworkTier',JSON_QUERY(@medical_formdata,'$.RxNetworkTier'));
							SET @FormData = JSON_MODIFY(@FormData,'$.RxServices',JSON_QUERY(@medical_formdata,'$.RxServices'));				--Added logic for creating RX section
							SET @FormData = JSON_MODIFY(@FormData,'$.RxAdditionalServices',JSON_QUERY(@medical_formdata,'$.RxAdditionalServices'));				--Added logic for creating RX section
							SET @FormData = JSON_MODIFY(@FormData,'$.RxProgramInformation',JSON_QUERY(@medical_formdata,'$.RxProgramInformation'));				--Added logic for creating RX section


							-- CompositeFormInstanceMap Table  entry

							Set @sourceDocID =Null
							Set @sourceFolderversionID =Null
							Set @sourceFolderID =Null
							Set @sourceFormInstanceID =Null

							Select top 1 @sourceDocID	=fi.docid		,
							@sourceFolderversionID=fv.FolderVersionID	,
							@sourceFolderID=f.folderid,
							@sourceFormInstanceID=fi.forminstanceid  from fldr.folder f
								inner join fldr.folderversion fv on f.folderid=fv.FolderID
								inner join fldr.forminstance fi on fv.FolderVersionID=fi.FolderVersionID and fi.FormDesignID=2405
								inner join #PackageSelectionProcessing p on f.Name=P.eBS_RX_COMPONENT
							and fi.name=eBS_RX_COMPONENT
							and P.eBS_PACKAGE_NAME=@PlanName
							order by fv.FolderVersionID desc

							if (@sourceDocID is not null and @sourceFolderversionID is not null And @sourceFolderID is not null and @sourceFormInstanceID is not null )
							Begin
								Insert into fldr.CompositeFormInstanceMap(SourceFormInstanceID
														,SourceDocID
														,SourceFolderVersionID
														,SourceFolderID
														,TargetFormInstanceID
														,TargetDocID
														,TargetFolderversionID
														,TargetFolderID
														,FormInstanceMapTypeID
														,CreatedDate
														,UpdatedDate
														,CreatedBy
														,UpdatedBy)
								Select @SourceFormInstanceID ,
													   @SourceDocID			 ,
													   @SourceFolderVersionID,
													   @SourceFolderID		 ,
													   @TargetFormInstanceID,
													   @TargetDocID,
													   @TargetFolderversionID,
													   @TargetFolderID,
													   @forminstancemaptypeidrx,
													   @CreatedDate,
													   @UpdatedDate,
													   @CreatedBy,
													   @UpdatedBy

							end
						end

						SET @FormData = JSON_MODIFY(@FormData,'$.PackageSelection.RxProductSelection',JSON_QUERY(@Section_FormData));

						SET @Section_FormData = NULL;




						SET @Section_FormData = JSON_QUERY(@FormData,'$.PackageSelection.DentalProductSelection');

				SELECT @FormInstanceID AS FormInstanceID,@PlanName AS PackageName,*
				INTO #PackageSelectionDentalProduct
				FROM OPENJSON(@Section_FormData) WITH (
					SelectDentalProduct		NVARCHAR(MAX),
					ProductID	Nvarchar(max),
					FolderName					NVARCHAR(MAX),
					[Version]						NVARCHAR(MAX),
					EffectiveDate				NVARCHAR(MAX)
				)

				UPDATE T
					SET T.SelectDentalProduct = isnull(D.eBS_Dental_COMPONENT,''),
					T.FolderName=isnull(D.eBS_Dental_COMPONENT,''),
						T.[Version] = isnull(D.Dental_Version,''),
						T.EffectiveDate= D.Dental_Effective_Date
				FROM #PackageSelectionDentalProduct T
				INNER JOIN #PackageSelectionProcessing D ON T.PackageName = D.eBS_PACKAGE_NAME


				SET @Section_FormData = NULL;
				SET @Section_FormData
									= JSON_QUERY((SELECT((
										SELECT DISTINCT SelectDentalProduct,ProductID,FolderName,[Version],EffectiveDate
											FROM #PackageSelectionDentalProduct FOR JSON PATH
										))))

				SET @Section_FormData = REPLACE(@Section_FormData, '[','');
				SET @Section_FormData = REPLACE(@Section_FormData, ']','');

				SET @medical_formdata = NULL
				Select @medical_formdata= formdata from #instanceList_Medical I inner join #PackageSelectionDentalProduct P on P.SelectDentalProduct=I.Name AND I.Producttype='Dental'

				if (@OfferDentalProduct = 'true' AND @medical_formdata IS NOT NULL)
				 begin
				SET @FormData = JSON_MODIFY(@FormData,'$.DentalProductRules',JSON_QUERY(@medical_formdata,'$.DentalProductRules'));
				SET @FormData = JSON_MODIFY(@FormData,'$.DentalDeductibleandMaximum',JSON_QUERY(@medical_formdata,'$.DentalDeductibleandMaximum'));
				SET @FormData = JSON_MODIFY(@FormData,'$.DentalClassCostShare',JSON_QUERY(@medical_formdata,'$.DentalClassCostShare'));
				SET @FormData = JSON_MODIFY(@FormData,'$.DentalBenefitReview',JSON_QUERY(@medical_formdata,'$.DentalBenefitReview'));
				SET @FormData = JSON_MODIFY(@FormData,'$.DentalLimits',JSON_QUERY(@medical_formdata,'$.DentalLimits'));
				SET @FormData = JSON_MODIFY(@FormData,'$.DentalNetworkandClass',JSON_QUERY(@medical_formdata,'$.DentalNetworkandClass'));
				SET @FormData = JSON_MODIFY(@FormData,'$.DentalRiders',JSON_QUERY(@medical_formdata,'$.DentalRiders'));			---Added logic for creating Dental section
				SET @FormData = JSON_MODIFY(@FormData,'$.DentalRates',JSON_QUERY(@medical_formdata,'$.DentalRates'));			---Added logic for creating Dental section

				-- CompositeFormInstanceMap Table  entry

				Set @sourceDocID =Null
				Set @sourceFolderversionID =Null
				Set @sourceFolderID =Null
				Set @sourceFormInstanceID =Null


				Select top 1 @sourceDocID	=fi.docid		,
			   @sourceFolderversionID=fv.FolderVersionID	,
			   @sourceFolderID=f.folderid,
			   @sourceFormInstanceID=fi.forminstanceid  from fldr.folder f
			   inner join fldr.folderversion fv on f.folderid=fv.FolderID
		inner join fldr.forminstance fi on fv.FolderVersionID=fi.FolderVersionID and fi.FormDesignID=2405
		inner join #PackageSelectionProcessing p on f.Name=P.eBS_Dental_COMPONENT
		and fi.name=eBS_Dental_COMPONENT
		 and P.eBS_PACKAGE_NAME=@PlanName
		order by fv.FolderVersionID desc

		if (@sourceDocID is not null and @sourceFolderversionID is not null And @sourceFolderID is not null and @sourceFormInstanceID is not null )
		Begin
		Insert into fldr.CompositeFormInstanceMap(SourceFormInstanceID
													,SourceDocID
													,SourceFolderVersionID
													,SourceFolderID
													,TargetFormInstanceID
													,TargetDocID
													,TargetFolderversionID
													,TargetFolderID
													,FormInstanceMapTypeID
													,CreatedDate
													,UpdatedDate
													,CreatedBy
													,UpdatedBy)
		Select @SourceFormInstanceID ,
			   @SourceDocID			 ,
			   @SourceFolderVersionID,
			   @SourceFolderID		 ,
			   @TargetFormInstanceID,
			   @TargetDocID,
			   @TargetFolderversionID,
			   @TargetFolderID,
			   @forminstancemaptypeiddental,
			   @CreatedDate,
			   @UpdatedDate,
			   @CreatedBy,
			   @UpdatedBy
	end
	end


				SET @FormData = JSON_MODIFY(@FormData,'$.PackageSelection.DentalProductSelection',JSON_QUERY(@Section_FormData));

				SET @Section_FormData = NULL;
	--			-------------------------------------------------------------------------------------
	--			--------------------------------------------------------------------------------


				SET @Section_FormData = JSON_QUERY(@FormData,'$.PackageSelection.VisionProductSelection');

				SELECT @FormInstanceID AS FormInstanceID,@PlanName AS PackageName,*
				INTO #PackageSelectionVisionProduct
				FROM OPENJSON(@Section_FormData) WITH (
					SelectVisionProduct		NVARCHAR(MAX),
					ProductID	Nvarchar(max),
					FolderName					NVARCHAR(MAX),
					[Version]						NVARCHAR(MAX),
					EffectiveDate				NVARCHAR(MAX)
				)

				UPDATE T
					SET T.SelectVisionProduct = isnull(D.eBS_Vision_COMPONENT,''),
					T.FolderName=isnull(D.eBS_Vision_COMPONENT,''),
						T.[version] = isnull(D.Vision_Version,''),
						T.[EffectiveDate]= D.Vision_Effective_Date
				FROM #PackageSelectionVisionProduct T
				INNER JOIN #PackageSelectionProcessing D ON T.PackageName = D.ebs_Package_Name

				SET @Section_FormData = NULL;

				SET @Section_FormData
									= JSON_QUERY((SELECT((
										SELECT DISTINCT SelectVisionProduct,ProductID,FolderName,[Version],EffectiveDate
											FROM #PackageSelectionVisionProduct FOR JSON PATH
										))))

				SET @Section_FormData = REPLACE(@Section_FormData, '[','');
				SET @Section_FormData = REPLACE(@Section_FormData, ']','');


				SET @medical_formdata=null;
				Select @medical_formdata=  formdata from #instanceList_Medical I inner join #PackageSelectionVisionProduct P on P.SelectVisionProduct=I.Name AND I.Producttype='Vision'

				 if (@OfferVisionProduct = 'true' AND @medical_formdata IS NOT NULL)
				 begin
				SET @FormData = JSON_MODIFY(@FormData,'$.VisionProductRules',JSON_QUERY(@medical_formdata,'$.VisionProductRules'));
				SET @FormData = JSON_MODIFY(@FormData,'$.VisionDeductibleMaximum',JSON_QUERY(@medical_formdata,'$.VisionDeductibleMaximum'));
				SET @FormData = JSON_MODIFY(@FormData,'$.VisionBenefitReview',JSON_QUERY(@medical_formdata,'$.VisionBenefitReview'));
				SET @FormData = JSON_MODIFY(@FormData,'$.VisionLimits',JSON_QUERY(@medical_formdata,'$.VisionLimits'));
				SET @FormData = JSON_MODIFY(@FormData,'$.VisionNetworkSelection',JSON_QUERY(@medical_formdata,'$.VisionNetworkSelection'));
				SET @FormData = JSON_MODIFY(@FormData,'$.VisionRates',JSON_QUERY(@medical_formdata,'$.VisionRates'));		-----Added logic for creating Vision section

				-- CompositeFormInstanceMap Table  entry

				Set @sourceDocID =Null
				Set @sourceFolderversionID =Null
				Set @sourceFolderID =Null
				Set @sourceFormInstanceID =Null

				Select top 1 @sourceDocID	=fi.docid		,
			   @sourceFolderversionID=fv.FolderVersionID	,
			   @sourceFolderID=f.folderid,
			   @sourceFormInstanceID=fi.forminstanceid  from fldr.folder f
			   inner join fldr.folderversion fv on f.folderid=fv.FolderID
		inner join fldr.forminstance fi on fv.FolderVersionID=fi.FolderVersionID and fi.FormDesignID=2405
		inner join #PackageSelectionProcessing p on f.Name=P.eBS_Vision_COMPONENT
		and fi.name=eBS_Vision_COMPONENT
		and P.eBS_PACKAGE_NAME=@PlanName
		order by fv.FolderVersionID desc

		if (@sourceDocID is not null and @sourceFolderversionID is not null And @sourceFolderID is not null and @sourceFormInstanceID is not null )
		Begin
		Insert into fldr.CompositeFormInstanceMap(SourceFormInstanceID
													,SourceDocID
													,SourceFolderVersionID
													,SourceFolderID
													,TargetFormInstanceID
													,TargetDocID
													,TargetFolderversionID
													,TargetFolderID
													,FormInstanceMapTypeID
													,CreatedDate
													,UpdatedDate
													,CreatedBy
													,UpdatedBy)
		Select @SourceFormInstanceID ,
			   @SourceDocID			 ,
			   @SourceFolderVersionID,
			   @SourceFolderID		 ,
			   @TargetFormInstanceID,
			   @TargetDocID,
			   @TargetFolderversionID,
			   @TargetFolderID,
			   @forminstancemaptypeidvision,
			   @CreatedDate,
			   @UpdatedDate,
			   @CreatedBy,
			   @UpdatedBy
				end
				end
				SET @FormData = JSON_MODIFY(@FormData,'$.PackageSelection.VisionProductSelection',JSON_QUERY(@Section_FormData));

-- QHPDetails population block (was disabled with IF 1=2, read from [Temp].[WY_LG_2027_Package_InputData_Testing]) removed.

SET @Section_FormData = JSON_QUERY(@FormData,'$.PackageSelection.HearingProductSelection');

						SELECT @FormInstanceID AS FormInstanceID,@PlanName AS PackageName,*
						INTO #PackageSelectionHearingProduct
						FROM OPENJSON(@Section_FormData) WITH (
							SelectHearingProduct		NVARCHAR(MAX),
							ProductID	Nvarchar(max),
							FolderName					NVARCHAR(MAX),
							[Version]					NVARCHAR(MAX),
							EffectiveDate				NVARCHAR(MAX))


						SET @Section_FormData = NULL;

						SET @Section_FormData
										= JSON_QUERY((SELECT((
											SELECT DISTINCT SelectHearingProduct,FolderName,[Version],EffectiveDate
												FROM #PackageSelectionHearingProduct FOR JSON PATH
											))))

						SET @FormData = JSON_MODIFY(@FormData,'$.PackageSelection.HearingProductSelection',JSON_QUERY(@Section_FormData));

						SET @Section_FormData = NULL;
						-------------------------------------------------------------------------------------
						--Update final formdata to Fldr.FormInstanceDataMap
						UPDATE D SET D.FormData = JSON_QUERY(ISNULL(@FormData,@Original_FormData)) FROM  Fldr.FormInstanceDataMap D WHERE FormInstanceID = @FormInstanceID;
					END

					UPDATE #PackageInstanceList SET IsProcessed = 1 WHERE FormInstanceID = @FormInstanceID;



				END

				SET @Comments = 'JSON updated successfully.'
			END TRY
			BEGIN CATCH
				SET @Comments = ERROR_MESSAGE() + ' occurred at ' + CAST(ERROR_LINE() AS VARCHAR(5));
			END CATCH

			UPDATE #PackageSelectList SET IsProcessed = 1, Comments = @Comments WHERE FolderID = @FolderID AND FolderVersionID = @FolderVersionID;

			-- FIX: surface section 004 failures in the app (previously only kept in #PackageSelectList.Comments,
			-- so the run still showed "Shell created successfully" even when the component merge failed).
			IF @Comments <> 'JSON updated successfully.'
			BEGIN
				UPDATE d
				SET d.RowStatus    = 'CreationFailed',
				    d.ErrorMessage = 'Package JSON update failed: ' + @Comments
				FROM AutoMig.AutoShellRunDetails d
				JOIN #PackageFolderMetaProcessing t ON d.DetailID = t.DetailID
			END


			-----------All views grouped under the anchor view and are active should be inserted if not exists, data generation will be taken care of by Save utility
             INSERT INTO [Fldr].[FormInstance] (
                 [FolderVersionID]
                ,[FormDesignID]
                ,[FormDesignVersionID]
                ,[Name]
                ,[TenantID]
                ,[AddedDate]
                ,[AddedBy]
                ,[UpdatedDate]
                ,[UpdatedBy]
                ,[IsActive]
                ,[AnchorDocumentID]
                ,[FormInstanceMapTypeId]
            )

            SELECT DISTINCT
                @FolderVersionID
                ,t.FormID [FormDesignID]
                ,MAX(fv.[FormDesignVersionID])
                ,@PkgFolderName [Name]
                ,@TenantID  [TenantID]
                ,GETDATE() [AddedDate]
                ,@UserID [AddedBy]
                ,GETDATE() [UpdatedDate]
                ,@UserID [UpdatedBy]
                ,1 [IsActive]
                ,(SELECT TOP 1 FormInstanceID FROM fldr.FormInstance FII (NOLOCK) WHERE FII.FolderVersionID = @FolderVersionID AND FII.FormDesignID = 2405)
                ,0
                FROM ui.FormDesignMapping tt (NOLOCK)
                INNER JOIN ui.formdesign t (NOLOCK) ON tt.TargetDesignID = t.FormID
                INNER JOIN ui.FormDesignVersion fv (NOLOCK) ON fv.FormDesignID = t.FormID
                WHERE tt.AnchorDesignID= 2405 AND t.IsActive = 1
                AND NOT EXISTS (SELECT 1 FROM Fldr.FormInstance FI (NOLOCK) WHERE FI.FolderVersionID = @FolderVersionID AND FI.FormDesignID = t.FormID)
                GROUP BY t.FormID
                ORDER by t.FormID


					----Generate Search View data
					EXEC [automig].[usp_generate_search_view_data] @businessFormInstanceID = @FormInstanceID;

					----Generate Account Product Map data
					EXEC [automig].[usp_generate_account_prouduct_map_data] @AnchorDocumentID = @FormInstanceID;

			---------------------Insert all the entries for MDM
            INSERT INTO [MDM].[DocumentUpdateTracker] (ForminstanceID,Status,AddedDate)
            SELECT fi.ForminstanceID, 1, GETDATE()
            FROM Fldr.FormInstance fi(NOLOCK)
            WHERE fi.FolderVersionID = @FolderVersionID
            AND NOT EXISTS (SELECT 1 FROM [MDM].[DocumentUpdateTracker] D (NOLOCK) WHERE D.FormInstanceID = fi.FormInstanceID)
            AND ISNULL(fi.Isactive,0) = 1
            AND fi.FormDesignID in (SELECT DISTINCT FormID FROM UI.FormDesign WHERE ISNULL(IsMDM,0) = 1)

			 ---------Updates Available for the Packages
			UPDATE  A SET A.UPDATEDDATE = GETDATE()
			from fldr.FormInstance A (NOLOCK)
			where forminstanceID in (SELECT FormInstanceID FROM #instanceList_Medical)

		END

		-------------************************************* 004.PackageselectionAndQHP : Finish **********************************************--------------------

		-- Sections 006/007 (UpdateBenefitInfoRepeater_SG / _IND) removed: 006 only marked folders processed (its update was commented out)
		-- and 007 looped over folders with ProductType = 'Medical', which Migration.packageListToBeMigrate_SG never contains for packages.

		-------------************************************* 008.updateddiseasemanagement_SG : Start **********************************************--------------------
		-- Stamp the default disease-management program list onto each Small Group Medical package.
		SET NOCOUNT ON;
		DROP TABLE IF EXISTS Temp.diseasemangementupdate_SG;

		SELECT F.FolderID, F.Name AS FolderName, FV.FolderVersionID ,CAST(0 AS BIT) IsProcessed , CAST('' as NVARCHAR(MAX))  AS Comments
		INTO Temp.diseasemangementupdate_SG
		FROM Fldr.Folder F (NOLOCK)
			INNER JOIN Fldr.FolderVersion FV (NOLOCK)on F.FolderID = FV.FolderID
			INNER JOIN Migration.packageListToBeMigrate_SG T (NOLOCK)ON F.Name = T.foldername
		ORDER BY F.FolderID DESC

		DECLARE @diseasemanagement Nvarchar(max)
		DECLARE @finalformdata NVARCHAR(MAX)
		DECLARE @PackageName NVARCHAR(MAX);

		SET @diseasemanagement='["Asthma","Heart Disease","Diabetes","High Blood Pressure & High Cholesterol","Pregnancy","Weight Loss Programs"]'
		WHILE EXISTS (SELECT 1 FROM Temp.diseasemangementupdate_SG WHERE IsProcessed = 0)
		BEGIN
			SET @FolderID = NULL;
			SET @FolderVersionID = NULL;

			SELECT TOP 1 @FolderID = FolderID, @FolderVersionID = FolderVersionID FROM Temp.diseasemangementupdate_SG WHERE IsProcessed = 0;

			IF OBJECT_ID ('tempdb..#MEDInstanceList2') IS NOT NULL
				DROP TABLE #MEDInstanceList2;

			SELECT DISTINCT FormInstanceID,[Name] AS PackageName, CAST(0 AS BIT) AS IsProcessed
			INTO #MEDInstanceList2
			FROM Fldr.FormInstance I (NOLOCK) WHERE FolderVersionID = @FolderVersionID
			AND FormDesignID = 2405;

			BEGIN TRY
				WHILE EXISTS (SELECT 1 FROM #MEDInstanceList2 WHERE IsProcessed = 0)
				BEGIN
					SET @finalformdata  = NULL;
					SET @FormInstanceID = NULL;
					SET @PackageName = NULL;
					SELECT TOP 1 @FormInstanceID = FormInstanceID, @PackageName = PackageName FROM #MEDInstanceList2 WHERE IsProcessed = 0;

					Update fldr.FormInstanceDataMap
					set formdata=json_modify(formdata,'$.QHPDetails.Planattributes.DiseaseManagementProgramsOffered',json_query(@diseasemanagement))
					where FormInstanceID=@FormInstanceID

					UPDATE #MEDInstanceList2 SET IsProcessed = 1 WHERE FormInstanceID = @FormInstanceID;
				END
				SET @Comments = 'JSON updated successfully.'
			END TRY
			BEGIN CATCH
				SET @Comments = ERROR_MESSAGE() + ' occurred at ' + CAST(ERROR_LINE() AS VARCHAR(5));
			END CATCH

			UPDATE Temp.diseasemangementupdate_SG SET IsProcessed = 1, Comments = @Comments WHERE FolderID = @FolderID AND FolderVersionID = @FolderVersionID;
		END
	-------------************************************* 008.updateddiseasemanagement_SG : Finish **********************************************--------------------

	END

	DROP TABLE IF EXISTS #PackageFolderMetaMatched
END
