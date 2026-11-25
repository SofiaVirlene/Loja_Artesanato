# 🧶 Loja Artesanal

Sistema de gerenciamento de uma loja virtual de artesanato, desenvolvido como projeto acadêmico para a disciplina de Banco de Dados II.

A aplicação permite gerenciar produtos artesanais, controlar o estoque, realizar compras, solicitar encomendas personalizadas e acompanhar processos de produção.

O sistema foi desenvolvido em Python, integrado a um banco de dados PostgreSQL, com funcionalidades específicas para cada perfil de usuário.

## 🎯 Objetivo do projeto

Desenvolver um sistema de gerenciamento para uma loja de artesanato, utilizando conceitos de banco de dados relacionais, programação e regras de negócio para organizar as operações comerciais e produtivas.

## ⚙️ Funcionalidades

- Cadastro e autenticação de clientes.
- Gerenciamento de produtos.
- Consulta e controle de estoque.
- Realização de compras.
- Solicitação de encomendas personalizadas.
- Aprovação e gerenciamento de pedidos.
- Registro e simulação de pagamentos.
- Gerenciamento de fabricantes.
- Atribuição e acompanhamento da produção.
- Atualização de status das encomendas e atividades de produção.

## 👥 Perfis de usuário

**Cliente:** pode consultar produtos, realizar compras e solicitar encomendas personalizadas.

**Gerente:** administra produtos, pedidos, estoque, fabricantes e atividades de produção.

**Fabricante:** consulta as atividades de produção atribuídas e atualiza seus respectivos status.

## 🛠️ Tecnologias utilizadas

- Python
- PostgreSQL
- SQL
- Psycopg2
- Python-dotenv

## 🗂️ Organização do projeto

```text
Loja_Artesanato/
│
├── database/
│   ├── 01_estrutura.sql
│   ├── 02_regras_negocio.sql
│   └── 03_dados_e_testes.sql
│
├── documentacao/
│   ├── Modelagem_Banco_Dados.pdf
│   └── Diagrama_Entidade_Relacionamento.pdf
│
├── App.py
├── requirements.txt
├── README.md
└── .gitignore
```

## 🚀 Como executar o projeto

### 1. Pré-requisitos

- Python instalado.
- PostgreSQL instalado.
- Banco de dados criado no PostgreSQL.

### 2. Instalação das dependências

No terminal, execute:

```bash
pip install -r requirements.txt
```

### 3. Configuração da conexão

Crie um arquivo `.env` na raiz do projeto e configure os dados de conexão com o PostgreSQL:

```env
DB_HOST=localhost
DB_PORT=5432
DB_NAME=loja_artesanato
DB_USER=postgres
DB_PASSWORD=sua_senha
```

Substitua `sua_senha` pela senha configurada no seu PostgreSQL.

### 4. Configuração do banco de dados

Execute os scripts SQL na seguinte ordem:

1. `01_estrutura.sql` — criação das tabelas e estrutura do banco.
2. `02_regras_negocio.sql` — criação das funções, procedimentos e gatilhos.
3. `03_dados_e_testes.sql` — inserção de dados e execução dos testes.

### 5. Inicialização da aplicação

Após configurar o banco de dados e a conexão, execute:

```bash
python App.py
```

## 📚 Documentação

A pasta `documentacao/` contém os arquivos em PDF referentes à modelagem do banco de dados e ao Diagrama Entidade-Relacionamento (DER).

## 🎓 Contexto acadêmico

Projeto desenvolvido para a disciplina de Banco de Dados II, no curso de Tecnologia em Análise e Desenvolvimento de Sistemas do Instituto Federal do Piauí (IFPI) — Campus Picos.
