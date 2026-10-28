// SFCS - ETL MongoDB -> SQL Server
// Índice usado pela extração incremental do WATCH (filtro por "update" + "type").
//
// Executar uma vez por banco de linha, por exemplo:
//   mongosh "mongodb://host.docker.internal:27027,host.docker.internal:27028,host.docker.internal:27029/?replicaSet=rs0" 01_CriarIndices.js
//
// Por padrão cria em todos os bancos thread_NN do servidor.

const bancos = db.adminCommand({ listDatabases: 1, nameOnly: true }).databases
  .map(d => d.name)
  .filter(n => /^thread_\d+$/.test(n));

for (const nome of bancos) {
  const w = db.getSiblingDB(nome).WATCH;
  const r = w.createIndex({ update: 1, type: 1 }, { name: 'ix_etl_update_type' });
  print(`${nome}.WATCH -> ${r}`);
}
