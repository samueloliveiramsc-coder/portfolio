/* =============================================================================
   Metronome - Camada de análise (Metronome_PRO -> Metronome_DW -> Power BI)
   01 - Banco de destino

   O Metronome_PRO é o banco transacional do SFCS (bobinas, interlocks, setups).
   As análises rodam numa cópia modelada (Metronome_DW) para não pesar na produção.
============================================================================= */
IF DB_ID(N'Metronome_DW') IS NULL
BEGIN
    -- mesma ordenação da origem: evita conflito de collation nas junções com src.*
    CREATE DATABASE Metronome_DW COLLATE SQL_Latin1_General_CP1_CI_AS;
END
GO

ALTER DATABASE Metronome_DW SET RECOVERY SIMPLE;
GO
