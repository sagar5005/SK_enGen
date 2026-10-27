-- ============================================================
-- Foundation Templates + Portfolio (Products) + Packages in ONE result set
-- DB: eBS_enGenHMK_UAT
-- Region filter: @State / @Region (default DE / DE), same as the package inventory query
-- RecordType = 'Foundation' | 'Portfolio' | 'Package'
-- Columns that do not apply to a RecordType are NULL.
-- ============================================================

DECLARE @State         NVARCHAR(50) = 'DE';
DECLARE @Region        NVARCHAR(50) = 'DE';
DECLARE @EffectiveYear INT          = NULL;   -- set to 2027 to restrict by version effective year, NULL = no year filter

;WITH LatestFolderVersions AS (
    -- Single-pass window function replaces per-row correlated subquery
    SELECT
        FolderVersionID,
        FolderID,
        FolderVersionNumber,
        EffectiveDate,
        FolderVersionStateID,
        ROW_NUMBER() OVER (PARTITION BY FolderID ORDER BY FolderVersionID DESC) AS rn_latest,
        ROW_NUMBER() OVER (
            PARTITION BY FolderID, FolderVersionStateID
            ORDER BY FolderVersionID DESC
        ) AS rn_by_state
    FROM fldr.FolderVersion WITH (NOLOCK)
),

-------------------------------------------------------------------------------
-- 1. FOUNDATION TEMPLATES
-------------------------------------------------------------------------------
FT AS (
    SELECT DISTINCT
        F.Name                              AS FoundationFolderName,
        FI.Name                             AS FoundationTemplateName,
        FV.FolderVersionNumber              AS FolderVersionNumber,
        FS.FolderVersionStateName           AS FolderVersionStateName,
        CAST(FV.EffectiveDate AS date)      AS EffectiveDate,
        F.MarketSegmentID                   AS MarketSegmentID,
        F.StateName                         AS StateName,
        FI.DOCID                            AS DOCID,
        FI.FormInstanceID                   AS FT_FormInstanceID
    FROM fldr.Folder F WITH (NOLOCK)
    INNER JOIN Fldr.FolderType FT
        ON F.FolderType = FT.TypeId
    INNER JOIN fldr.FolderVersion FV WITH (NOLOCK)
        ON F.FolderID = FV.FolderID
    INNER JOIN fldr.FolderVersionState FS
        ON FV.FolderVersionStateID = FS.FolderVersionStateID
    INNER JOIN fldr.FormInstance FI WITH (NOLOCK)
        ON FI.FolderVersionID = FV.FolderVersionID
    INNER JOIN fldr.FormInstanceDataMap FID WITH (NOLOCK)
        ON FI.FormInstanceID = FID.FormInstanceID
    WHERE F.FolderType = 3
      AND FI.IsActive = 1
      AND FI.FormDesignID = 2405
      AND F.StateName = @State
      AND F.Region    = @Region
      AND (@EffectiveYear IS NULL OR YEAR(FV.EffectiveDate) = @EffectiveYear)
      AND (
          -- all released versions
          FV.FolderVersionStateID = 3
          OR
          -- latest version of each folder (any state)
          FV.FolderVersionID IN (
              SELECT MAX(FV2.FolderVersionID)
              FROM fldr.FolderVersion FV2 WITH (NOLOCK)
              GROUP BY FV2.FolderID
          )
      )
),

-------------------------------------------------------------------------------
-- 2. PORTFOLIO (PRODUCTS)
-- FolderType = 1 are the product (component) folders, same filter the shell SP uses.
-------------------------------------------------------------------------------
PortfolioSource AS (
    SELECT DISTINCT
        CASE WHEN ac.AccountID IS NOT NULL THEN 'True' ELSE 'False' END AS IsFromAccount,
        pf_fi.FormInstanceID                AS PortfolioFormInstanceID,
        pf_fi.DOCID                         AS DOCID,
        pf_f.Name                           AS PortfolioFolderName,
        pf_fi.Name                          AS PortfolioProductName,
        pf_fv.FolderVersionNumber           AS PortfolioFolderVersionNumber,
        pf_fvs.FolderVersionStateName       AS PortfolioFolderVersionStateName,
        CAST(pf_fv.EffectiveDate AS date)   AS PortfolioEffectiveDate,
        pf_f.MarketSegmentID                AS PortfolioMarketSegmentID,
        pf_f.StateName                      AS PortfolioStateName,
        pf_fv.FolderVersionID               AS PortfolioFolderVersionID
    FROM fldr.FormInstance pf_fi WITH (NOLOCK)
    JOIN fldr.FolderVersion pf_fv WITH (NOLOCK)
        ON pf_fv.FolderVersionID = pf_fi.FolderVersionID
    JOIN LatestFolderVersions lfv
        ON lfv.FolderVersionID = pf_fv.FolderVersionID
    JOIN fldr.Folder pf_f WITH (NOLOCK)
        ON pf_f.FolderID = pf_fv.FolderID
    JOIN fldr.FolderVersionState pf_fvs
        ON pf_fvs.FolderVersionStateID = pf_fv.FolderVersionStateID
    LEFT JOIN Accn.AccountFolderMap ac
        ON ac.FolderID = pf_f.FolderID
    WHERE pf_fi.FormDesignID = 2405
      AND pf_fi.IsActive = 1
      AND pf_f.FolderType = 1
      AND pf_f.StateName = @State
      AND pf_f.Region    = @Region
      AND (@EffectiveYear IS NULL OR YEAR(pf_fv.EffectiveDate) = @EffectiveYear)
      AND (pf_fv.FolderVersionStateID = 3 OR lfv.rn_latest = 1)
),

Portfolio AS (
    SELECT
        ps.PortfolioFormInstanceID,
        ps.DOCID,
        ps.IsFromAccount,
        ps.PortfolioFolderName,
        ps.PortfolioProductName,
        ps.PortfolioFolderVersionNumber,
        ps.PortfolioFolderVersionStateName,
        ps.PortfolioEffectiveDate,
        ps.PortfolioMarketSegmentID,
        ps.PortfolioStateName,
        ft_ref.FoundationTemplate,
        ft_ref.FoundationFolderName,
        ft_ref.FoundationFolderVersionNumber
    FROM PortfolioSource ps
    -- Foundation template used by the product, from Accn.AccountProductMap (same link as the inventory query)
    OUTER APPLY (
        SELECT TOP 1
            apm.FoundationTemplate              AS FoundationTemplate,
            ft_f.Name                           AS FoundationFolderName,
            ft_lv.FolderVersionNumber           AS FoundationFolderVersionNumber
        FROM Accn.AccountProductMap apm WITH (NOLOCK)
        JOIN fldr.Folder ft_f WITH (NOLOCK)
            ON ft_f.Name = apm.FoundationTemplate AND ft_f.IsFoundation = 1
        JOIN LatestFolderVersions ft_lv
            ON ft_lv.FolderID = ft_f.FolderID AND ft_lv.rn_latest = 1
        WHERE apm.FolderVersionID = ps.PortfolioFolderVersionID
    ) ft_ref
),

-------------------------------------------------------------------------------
-- 3. PACKAGES (one row per package, components as columns)
-------------------------------------------------------------------------------
PackageSource AS (
    -- Unified source for both account-linked and plan-linked packages
    SELECT
        CASE WHEN ac.AccountID IS NOT NULL THEN 'True' ELSE 'False' END AS IsFromAccount,
        pk_fi.FormInstanceID        AS pk_fi_id,
        pk_f.Name                   AS pk_folder_name,
        pk_fv.FolderVersionNumber   AS pk_folder_v,
        pk_fi.Name                  AS pk_name,
        pk_fi.DOCID
    FROM fldr.FormInstance pk_fi WITH (NOLOCK)
    JOIN fldr.FolderVersion pk_fv WITH (NOLOCK)
        ON pk_fv.FolderVersionID = pk_fi.FolderVersionID
    JOIN LatestFolderVersions lfv
        ON lfv.FolderVersionID = pk_fv.FolderVersionID
    JOIN fldr.Folder pk_f WITH (NOLOCK)
        ON pk_f.FolderID = pk_fv.FolderID
    JOIN fldr.CompositeFormInstanceMap cfim WITH (NOLOCK)
        ON cfim.TargetFormInstanceID = pk_fi.FormInstanceID
    -- Account join (LEFT, null = plan-linked package)
    LEFT JOIN Accn.AccountFolderMap ac
        ON ac.FolderID = pk_f.FolderID
    LEFT JOIN Accn.Account acn
        ON acn.AccountID = ac.AccountID
    WHERE pk_fi.FormDesignID = 2405
      AND pk_fi.IsActive = 1
      AND pk_f.FolderType IN (2, 4, 5)
      AND pk_f.StateName = @State
      AND pk_f.Region    = @Region
      AND pk_f.[Name] NOT LIKE '%discontinue%'
      AND (@EffectiveYear IS NULL OR YEAR(pk_fv.EffectiveDate) = @EffectiveYear)
      AND (
          -- Account-linked: must have an active account
          (pk_f.FolderType IN (2, 4) AND acn.AccountName IS NOT NULL AND acn.IsActive = 1)
          OR
          -- Plan-linked: folder type 5, released or latest draft version
          (pk_f.FolderType = 5
           AND (
               pk_fv.FolderVersionStateID = 3
               OR (pk_fv.FolderVersionStateID = 1 AND lfv.rn_by_state = 1)
           ))
      )
),

ProductOptions AS (
    -- Component (Medical/Rx/Dental/Vision) details, joined once and reused
    SELECT
        cfim.TargetFormInstanceID,
        po_fi.Name                      AS po_name,
        po_fv.FolderVersionNumber       AS po_folder_v,
        po_f.Name                       AS po_folder_name,
        po_fimt.FormInstanceMapType     AS po_type
    FROM fldr.CompositeFormInstanceMap cfim WITH (NOLOCK)
    JOIN fldr.FormInstance po_fi WITH (NOLOCK)
        ON po_fi.FormInstanceID = cfim.SourceFormInstanceID
    JOIN fldr.FolderVersion po_fv WITH (NOLOCK)
        ON po_fv.FolderVersionID = po_fi.FolderVersionID
    JOIN fldr.Folder po_f WITH (NOLOCK)
        ON po_f.FolderID = po_fv.FolderID
    -- Map type comes from the mapping row itself, not from the source instance
    JOIN fldr.FormInstanceMapType po_fimt
        ON po_fimt.FormInstanceMapTypeID = cfim.FormInstanceMapTypeID
),

Pkg AS (
    SELECT
        ps.pk_fi_id         AS PackageFormInstanceID,
        ps.DOCID,
        ps.IsFromAccount,
        ps.pk_folder_name   AS PackageFolderName,
        ps.pk_folder_v      AS FolderVersionNumber,
        ps.pk_name          AS PackageName,

        MAX(CASE WHEN po.po_type = 'medical' THEN po.po_folder_name END) AS MedicalFolderName,
        MAX(CASE WHEN po.po_type = 'medical' THEN po.po_folder_v    END) AS MedicalProductVersion,
        MAX(CASE WHEN po.po_type = 'medical' THEN po.po_name        END) AS MedicalProductName,

        MAX(CASE WHEN po.po_type = 'rx'      THEN po.po_folder_name END) AS RXFolderName,
        MAX(CASE WHEN po.po_type = 'rx'      THEN po.po_folder_v    END) AS RXProductVersion,
        MAX(CASE WHEN po.po_type = 'rx'      THEN po.po_name        END) AS RxProductName,

        MAX(CASE WHEN po.po_type = 'dental'  THEN po.po_folder_name END) AS DentalFolderName,
        MAX(CASE WHEN po.po_type = 'dental'  THEN po.po_folder_v    END) AS DentalProductVersion,
        MAX(CASE WHEN po.po_type = 'dental'  THEN po.po_name        END) AS DentalProductName,

        MAX(CASE WHEN po.po_type = 'vision'  THEN po.po_folder_name END) AS VisionFolderName,
        MAX(CASE WHEN po.po_type = 'vision'  THEN po.po_folder_v    END) AS VisionProductVersion,
        MAX(CASE WHEN po.po_type = 'vision'  THEN po.po_name        END) AS VisionProductName
    FROM PackageSource ps
    JOIN ProductOptions po
        ON po.TargetFormInstanceID = ps.pk_fi_id
    GROUP BY
        ps.pk_fi_id,
        ps.DOCID,
        ps.IsFromAccount,
        ps.pk_folder_name,
        ps.pk_folder_v,
        ps.pk_name
)

-------------------------------------------------------------------------------
-- ONE RESULT SET
-------------------------------------------------------------------------------
SELECT
    RecordType,
    DOCID,
    IsFromAccount,

    -- Foundation
    FoundationFolderName,
    FoundationTemplateName,
    FolderVersionNumber,
    FolderVersionStateName,
    EffectiveDate,
    MarketSegmentID,
    StateName,
    FT_FormInstanceID,

    -- Package
    PackageFormInstanceID,
    PackageFolderName,
    PackageName,
    MedicalFolderName,  MedicalProductVersion,  MedicalProductName,
    RXFolderName,       RXProductVersion,       RxProductName,
    DentalFolderName,   DentalProductVersion,   DentalProductName,
    VisionFolderName,   VisionProductVersion,   VisionProductName,

    -- Portfolio
    PortfolioFormInstanceID,
    PortfolioFolderName,
    PortfolioProductName,
    PortfolioFolderVersionNumber,
    PortfolioFolderVersionStateName,
    PortfolioEffectiveDate,
    PortfolioMarketSegmentID,
    PortfolioStateName,
    FoundationTemplate,
    FoundationFolderVersionNumber
FROM (
    -- Foundation rows
    SELECT
        CAST('Foundation' AS VARCHAR(20))   AS RecordType,
        DOCID,
        CAST(NULL AS VARCHAR(5))            AS IsFromAccount,
        FoundationFolderName,
        FoundationTemplateName,
        FolderVersionNumber,
        FolderVersionStateName,
        EffectiveDate,
        MarketSegmentID,
        StateName,
        FT_FormInstanceID,
        CAST(NULL AS INT)                   AS PackageFormInstanceID,
        CAST(NULL AS NVARCHAR(500))         AS PackageFolderName,
        CAST(NULL AS NVARCHAR(500))         AS PackageName,
        CAST(NULL AS NVARCHAR(500))         AS MedicalFolderName,
        CAST(NULL AS NVARCHAR(100))         AS MedicalProductVersion,
        CAST(NULL AS NVARCHAR(500))         AS MedicalProductName,
        CAST(NULL AS NVARCHAR(500))         AS RXFolderName,
        CAST(NULL AS NVARCHAR(100))         AS RXProductVersion,
        CAST(NULL AS NVARCHAR(500))         AS RxProductName,
        CAST(NULL AS NVARCHAR(500))         AS DentalFolderName,
        CAST(NULL AS NVARCHAR(100))         AS DentalProductVersion,
        CAST(NULL AS NVARCHAR(500))         AS DentalProductName,
        CAST(NULL AS NVARCHAR(500))         AS VisionFolderName,
        CAST(NULL AS NVARCHAR(100))         AS VisionProductVersion,
        CAST(NULL AS NVARCHAR(500))         AS VisionProductName,
        CAST(NULL AS INT)                   AS PortfolioFormInstanceID,
        CAST(NULL AS NVARCHAR(500))         AS PortfolioFolderName,
        CAST(NULL AS NVARCHAR(500))         AS PortfolioProductName,
        CAST(NULL AS NVARCHAR(100))         AS PortfolioFolderVersionNumber,
        CAST(NULL AS NVARCHAR(100))         AS PortfolioFolderVersionStateName,
        CAST(NULL AS DATE)                  AS PortfolioEffectiveDate,
        CAST(NULL AS NVARCHAR(200))         AS PortfolioMarketSegmentID,
        CAST(NULL AS NVARCHAR(100))         AS PortfolioStateName,
        CAST(NULL AS NVARCHAR(500))         AS FoundationTemplate,
        CAST(NULL AS NVARCHAR(100))         AS FoundationFolderVersionNumber
    FROM FT

    UNION ALL

    -- Portfolio (product) rows
    SELECT
        'Portfolio',
        DOCID,
        IsFromAccount,
        FoundationFolderName,
        CAST(NULL AS NVARCHAR(500)),
        CAST(NULL AS NVARCHAR(100)),
        CAST(NULL AS NVARCHAR(100)),
        CAST(NULL AS DATE),
        CAST(NULL AS NVARCHAR(200)),
        CAST(NULL AS NVARCHAR(100)),
        CAST(NULL AS INT),
        CAST(NULL AS INT),
        CAST(NULL AS NVARCHAR(500)),
        CAST(NULL AS NVARCHAR(500)),
        CAST(NULL AS NVARCHAR(500)), CAST(NULL AS NVARCHAR(100)), CAST(NULL AS NVARCHAR(500)),
        CAST(NULL AS NVARCHAR(500)), CAST(NULL AS NVARCHAR(100)), CAST(NULL AS NVARCHAR(500)),
        CAST(NULL AS NVARCHAR(500)), CAST(NULL AS NVARCHAR(100)), CAST(NULL AS NVARCHAR(500)),
        CAST(NULL AS NVARCHAR(500)), CAST(NULL AS NVARCHAR(100)), CAST(NULL AS NVARCHAR(500)),
        PortfolioFormInstanceID,
        PortfolioFolderName,
        PortfolioProductName,
        PortfolioFolderVersionNumber,
        PortfolioFolderVersionStateName,
        PortfolioEffectiveDate,
        PortfolioMarketSegmentID,
        PortfolioStateName,
        FoundationTemplate,
        FoundationFolderVersionNumber
    FROM Portfolio

    UNION ALL

    -- Package rows
    SELECT
        'Package',
        DOCID,
        IsFromAccount,
        CAST(NULL AS NVARCHAR(500)),
        CAST(NULL AS NVARCHAR(500)),
        FolderVersionNumber,
        CAST(NULL AS NVARCHAR(100)),
        CAST(NULL AS DATE),
        CAST(NULL AS NVARCHAR(200)),
        CAST(NULL AS NVARCHAR(100)),
        CAST(NULL AS INT),
        PackageFormInstanceID,
        PackageFolderName,
        PackageName,
        MedicalFolderName,  MedicalProductVersion,  MedicalProductName,
        RXFolderName,       RXProductVersion,       RxProductName,
        DentalFolderName,   DentalProductVersion,   DentalProductName,
        VisionFolderName,   VisionProductVersion,   VisionProductName,
        CAST(NULL AS INT),
        CAST(NULL AS NVARCHAR(500)),
        CAST(NULL AS NVARCHAR(500)),
        CAST(NULL AS NVARCHAR(100)),
        CAST(NULL AS NVARCHAR(100)),
        CAST(NULL AS DATE),
        CAST(NULL AS NVARCHAR(200)),
        CAST(NULL AS NVARCHAR(100)),
        CAST(NULL AS NVARCHAR(500)),
        CAST(NULL AS NVARCHAR(100))
    FROM Pkg
) AS AllRows
ORDER BY RecordType, FoundationFolderName, PackageFolderName, PortfolioFolderName;
