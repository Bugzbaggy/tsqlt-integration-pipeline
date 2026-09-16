-- =============================================================================
-- bootstrap.sql — provision a AppDb_MSG-schema database before the dacpac publish.
-- Parameterized by SQLCMD variable DbName so the same script serves the Dev and
-- SIT instances (AppDb_SIT is the SIT-env copy of the AppDb_MSG schema):
--   sqlcmd -v DbName=AppDb_MSG_Dev  -i bootstrap.sql
--   sqlcmd -v DbName=AppDb_SIT  -i bootstrap.sql
--
-- Creates the DB, its 6 filegroups WITH a data file each (route.PriceListHistory is
-- partitioned on PS_PartitionKey — a fileless filegroup fails CREATE TABLE, Msg 622),
-- and the Database Master Key the 7 self-signed certificates require (else error 15581).
-- Runs before publish; publish then uses CreateNewDatabase=False. Fresh container per
-- run, so no IF-EXISTS guards on the filegroups are needed.
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
GO
ALTER DATABASE [$(DbName)] ADD FILE (NAME = N'$(DbName)_FG_01', FILENAME = N'/var/opt/mssql/data/$(DbName)_FG_01.ndf', SIZE = 16MB, FILEGROWTH = 32MB) TO FILEGROUP [FG_01];
ALTER DATABASE [$(DbName)] ADD FILE (NAME = N'$(DbName)_FG_02', FILENAME = N'/var/opt/mssql/data/$(DbName)_FG_02.ndf', SIZE = 16MB, FILEGROWTH = 32MB) TO FILEGROUP [FG_02];
ALTER DATABASE [$(DbName)] ADD FILE (NAME = N'$(DbName)_FG_03', FILENAME = N'/var/opt/mssql/data/$(DbName)_FG_03.ndf', SIZE = 16MB, FILEGROWTH = 32MB) TO FILEGROUP [FG_03];
ALTER DATABASE [$(DbName)] ADD FILE (NAME = N'$(DbName)_FG_04', FILENAME = N'/var/opt/mssql/data/$(DbName)_FG_04.ndf', SIZE = 16MB, FILEGROWTH = 32MB) TO FILEGROUP [FG_04];
ALTER DATABASE [$(DbName)] ADD FILE (NAME = N'$(DbName)_FG_05', FILENAME = N'/var/opt/mssql/data/$(DbName)_FG_05.ndf', SIZE = 16MB, FILEGROWTH = 32MB) TO FILEGROUP [FG_05];
ALTER DATABASE [$(DbName)] ADD FILE (NAME = N'$(DbName)_FG_06', FILENAME = N'/var/opt/mssql/data/$(DbName)_FG_06.ndf', SIZE = 16MB, FILEGROWTH = 32MB) TO FILEGROUP [FG_06];
GO
USE [$(DbName)];
GO
-- Throwaway LOCAL-DEV-ONLY password; never a real/prod DMK password (must not live in git).
-- The DMK is regenerated fresh each run and auto-encrypted by the SMK, so it opens
-- automatically for ENCRYPTBYKEY/DECRYPTBYKEY — the value only needs to be a non-secret constant.
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'L0c@lD3vSQL';
GO
PRINT 'bootstrap.sql applied to $(DbName).';
GO
