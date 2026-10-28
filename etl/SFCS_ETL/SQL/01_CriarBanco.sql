/* =============================================================================
   SFCS - ETL MongoDB (SPEND / WATCH) -> SQL Server -> Power BI
   01 - Criação do banco de destino (target)

   Execute conectado ao SQL Server de destino (SQL Server 2016+; testado no 2019).
   O banco precisa de nível de compatibilidade >= 130 por causa do OPENJSON.
============================================================================= */
USE master;
GO

IF DB_ID(N'SFCS_DW') IS NULL
    CREATE DATABASE SFCS_DW;
GO

-- Dados reprocessáveis a partir do MongoDB: recovery SIMPLE evita crescimento do log.
ALTER DATABASE SFCS_DW SET RECOVERY SIMPLE;
GO

IF (SELECT compatibility_level FROM sys.databases WHERE name = N'SFCS_DW') < 130
    ALTER DATABASE SFCS_DW SET COMPATIBILITY_LEVEL = 130;
GO
