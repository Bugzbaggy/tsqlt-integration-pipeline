-- =============================================================================
-- bootstrap.data.sql — provision the AppDb_MSG_data database before its dacpac publish.
-- Parameterized by SQLCMD variable DbName (default AppDb_MSG_Data_Dev):
--   sqlcmd -v DbName=AppDb_MSG_Data_Dev -i bootstrap.data.sql
--
-- AppDb_MSG_data has 12 filegroups (FG_01..FG_12) feeding 5 partition schemes
-- (PS_Month, PS_BYDAY180/90/62/31) used by the large stat/log tables — each needs a
-- data file or CREATE TABLE fails (Msg 622). No certificates in this project, so a
-- DMK is not strictly required, but it is created for parity/harmlessness.
-- Filegroups are listed explicitly (no dynamic SQL) so the file passes sql-valid8.
-- Fresh container per run, so no IF-EXISTS guards on the filegroups.
-- =============================================================================
SET NOCOUNT ON;
GO
IF DB_ID(N'$(DbName)') IS NULL
    CREATE DATABASE [$(DbName)];
GO
ALTER DATABASE [$(DbName)] ADD FILEGROUP [FG_01];
ALTER DATABASE [$(DbName)] ADD FILEGROUP [FG_02];
ALTER DATABASE [$(DbName)] ADD FILEGROUP [FG_03];
ALTER DATABASE [$(DbName)] ADD FILEGROUP [FG_04];
ALTER DATABASE [$(DbName)] ADD FILEGROUP [FG_05];
ALTER DATABASE [$(DbName)] ADD FILEGROUP [FG_06];
ALTER DATABASE [$(DbName)] ADD FILEGROUP [FG_07];
ALTER DATABASE [$(DbName)] ADD FILEGROUP [FG_08];
ALTER DATABASE [$(DbName)] ADD FILEGROUP [FG_09];
ALTER DATABASE [$(DbName)] ADD FILEGROUP [FG_10];
ALTER DATABASE [$(DbName)] ADD FILEGROUP [FG_11];
ALTER DATABASE [$(DbName)] ADD FILEGROUP [FG_12];
GO
ALTER DATABASE [$(DbName)] ADD FILE (NAME = N'$(DbName)_FG_01', FILENAME = N'/var/opt/mssql/data/$(DbName)_FG_01.ndf', SIZE = 16MB, FILEGROWTH = 32MB) TO FILEGROUP [FG_01];
ALTER DATABASE [$(DbName)] ADD FILE (NAME = N'$(DbName)_FG_02', FILENAME = N'/var/opt/mssql/data/$(DbName)_FG_02.ndf', SIZE = 16MB, FILEGROWTH = 32MB) TO FILEGROUP [FG_02];
ALTER DATABASE [$(DbName)] ADD FILE (NAME = N'$(DbName)_FG_03', FILENAME = N'/var/opt/mssql/data/$(DbName)_FG_03.ndf', SIZE = 16MB, FILEGROWTH = 32MB) TO FILEGROUP [FG_03];
ALTER DATABASE [$(DbName)] ADD FILE (NAME = N'$(DbName)_FG_04', FILENAME = N'/var/opt/mssql/data/$(DbName)_FG_04.ndf', SIZE = 16MB, FILEGROWTH = 32MB) TO FILEGROUP [FG_04];
ALTER DATABASE [$(DbName)] ADD FILE (NAME = N'$(DbName)_FG_05', FILENAME = N'/var/opt/mssql/data/$(DbName)_FG_05.ndf', SIZE = 16MB, FILEGROWTH = 32MB) TO FILEGROUP [FG_05];
ALTER DATABASE [$(DbName)] ADD FILE (NAME = N'$(DbName)_FG_06', FILENAME = N'/var/opt/mssql/data/$(DbName)_FG_06.ndf', SIZE = 16MB, FILEGROWTH = 32MB) TO FILEGROUP [FG_06];
ALTER DATABASE [$(DbName)] ADD FILE (NAME = N'$(DbName)_FG_07', FILENAME = N'/var/opt/mssql/data/$(DbName)_FG_07.ndf', SIZE = 16MB, FILEGROWTH = 32MB) TO FILEGROUP [FG_07];
ALTER DATABASE [$(DbName)] ADD FILE (NAME = N'$(DbName)_FG_08', FILENAME = N'/var/opt/mssql/data/$(DbName)_FG_08.ndf', SIZE = 16MB, FILEGROWTH = 32MB) TO FILEGROUP [FG_08];
ALTER DATABASE [$(DbName)] ADD FILE (NAME = N'$(DbName)_FG_09', FILENAME = N'/var/opt/mssql/data/$(DbName)_FG_09.ndf', SIZE = 16MB, FILEGROWTH = 32MB) TO FILEGROUP [FG_09];
ALTER DATABASE [$(DbName)] ADD FILE (NAME = N'$(DbName)_FG_10', FILENAME = N'/var/opt/mssql/data/$(DbName)_FG_10.ndf', SIZE = 16MB, FILEGROWTH = 32MB) TO FILEGROUP [FG_10];
ALTER DATABASE [$(DbName)] ADD FILE (NAME = N'$(DbName)_FG_11', FILENAME = N'/var/opt/mssql/data/$(DbName)_FG_11.ndf', SIZE = 16MB, FILEGROWTH = 32MB) TO FILEGROUP [FG_11];
ALTER DATABASE [$(DbName)] ADD FILE (NAME = N'$(DbName)_FG_12', FILENAME = N'/var/opt/mssql/data/$(DbName)_FG_12.ndf', SIZE = 16MB, FILEGROWTH = 32MB) TO FILEGROUP [FG_12];
GO
USE [$(DbName)];
GO
-- Throwaway LOCAL-DEV-ONLY password; never a real/prod DMK password (must not live in git).
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'L0c@lD3vSQL';
GO
PRINT 'bootstrap.data.sql applied to $(DbName).';
GO
