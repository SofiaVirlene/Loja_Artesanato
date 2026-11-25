-- =============================================================================
-- LOJA VIRTUAL DE ARTESANATO - Banco de Dados II (IFPI - Campus Picos)
-- Arquivo 1 de 3: ESTRUTURA (tabelas, chaves, restrições e índices)
-- SGBD: PostgreSQL 14 ou superior
--
-- Como executar (exemplo no terminal):
--   createdb loja_artesanato
--   psql -d loja_artesanato -f 01_estrutura.sql
--   psql -d loja_artesanato -f 02_regras_negocio.sql
--   psql -d loja_artesanato -f 03_dados_e_testes.sql
-- =============================================================================

-- pgcrypto: usado para gerar o hash seguro das senhas (função crypt)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- -----------------------------------------------------------------------------
-- Função auxiliar: validação de CPF (dígitos verificadores)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_cpf_valido(p_cpf TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    v_soma INT;
    v_dv1  INT;
    v_dv2  INT;
    i      INT;
BEGIN
    IF p_cpf IS NULL OR p_cpf !~ '^[0-9]{11}$' THEN
        RETURN FALSE;
    END IF;
    -- rejeita sequências repetidas (000.000.000-00, 111.111.111-11, ...)
    IF p_cpf ~ '^(.)\1{10}$' THEN
        RETURN FALSE;
    END IF;

    v_soma := 0;
    FOR i IN 1..9 LOOP
        v_soma := v_soma + substr(p_cpf, i, 1)::INT * (11 - i);
    END LOOP;
    v_dv1 := (v_soma * 10) % 11;
    IF v_dv1 = 10 THEN v_dv1 := 0; END IF;

    v_soma := 0;
    FOR i IN 1..10 LOOP
        v_soma := v_soma + substr(p_cpf, i, 1)::INT * (12 - i);
    END LOOP;
    v_dv2 := (v_soma * 10) % 11;
    IF v_dv2 = 10 THEN v_dv2 := 0; END IF;

    RETURN v_dv1 = substr(p_cpf, 10, 1)::INT AND v_dv2 = substr(p_cpf, 11, 1)::INT;
END;
$$;

-- =============================================================================
-- USUÁRIOS E ESPECIALIZAÇÕES (total e disjunta)
-- Disjunta: cada perfil guarda tipo_usuario fixo e referencia (id_usuario, tipo_usuario)
--           de USUARIO; assim um usuário não pode estar em dois perfis.
-- Total:    trigger adiada em 02_regras_negocio.sql garante que todo usuário
--           possui a linha do seu perfil ao final da transação.
-- =============================================================================
CREATE TABLE usuario (
    id_usuario    INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome          VARCHAR(120) NOT NULL,
    email         VARCHAR(150) NOT NULL,
    senha_hash    VARCHAR(255) NOT NULL,
    tipo_usuario  VARCHAR(20)  NOT NULL,
    data_cadastro TIMESTAMP    NOT NULL DEFAULT now(),
    status        BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_usuario_email UNIQUE (email),
    CONSTRAINT uq_usuario_id_tipo UNIQUE (id_usuario, tipo_usuario),
    CONSTRAINT ck_usuario_tipo CHECK (tipo_usuario IN ('CLIENTE', 'GERENTE', 'FABRICANTE')),
    CONSTRAINT ck_usuario_email CHECK (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
);

CREATE TABLE cliente (
    id_usuario      INTEGER PRIMARY KEY,
    tipo_usuario    VARCHAR(20) NOT NULL DEFAULT 'CLIENTE',
    cpf             VARCHAR(11),
    data_nascimento DATE,
    CONSTRAINT uq_cliente_cpf UNIQUE (cpf),
    CONSTRAINT ck_cliente_tipo CHECK (tipo_usuario = 'CLIENTE'),
    CONSTRAINT ck_cliente_cpf CHECK (cpf IS NULL OR fn_cpf_valido(cpf)),
    CONSTRAINT ck_cliente_nascimento CHECK (data_nascimento IS NULL OR data_nascimento <= CURRENT_DATE),
    CONSTRAINT fk_cliente_usuario FOREIGN KEY (id_usuario, tipo_usuario)
        REFERENCES usuario (id_usuario, tipo_usuario) ON DELETE CASCADE
);

CREATE TABLE gerente (
    id_usuario   INTEGER PRIMARY KEY,
    tipo_usuario VARCHAR(20) NOT NULL DEFAULT 'GERENTE',
    nivel_acesso VARCHAR(30) NOT NULL,
    CONSTRAINT ck_gerente_tipo CHECK (tipo_usuario = 'GERENTE'),
    CONSTRAINT ck_gerente_nivel CHECK (nivel_acesso IN ('BASICO', 'ADMINISTRADOR')),
    CONSTRAINT fk_gerente_usuario FOREIGN KEY (id_usuario, tipo_usuario)
        REFERENCES usuario (id_usuario, tipo_usuario) ON DELETE CASCADE
);

CREATE TABLE fabricante (
    id_usuario    INTEGER PRIMARY KEY,
    tipo_usuario  VARCHAR(20) NOT NULL DEFAULT 'FABRICANTE',
    especialidade VARCHAR(100),
    CONSTRAINT ck_fabricante_tipo CHECK (tipo_usuario = 'FABRICANTE'),
    CONSTRAINT fk_fabricante_usuario FOREIGN KEY (id_usuario, tipo_usuario)
        REFERENCES usuario (id_usuario, tipo_usuario) ON DELETE CASCADE
);

CREATE TABLE endereco (
    id_endereco        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_usuario         INTEGER      NOT NULL REFERENCES usuario (id_usuario) ON DELETE CASCADE,
    cep                VARCHAR(8)   NOT NULL,
    logradouro         VARCHAR(150) NOT NULL,
    numero             VARCHAR(15)  NOT NULL,
    complemento        VARCHAR(100),
    bairro             VARCHAR(100) NOT NULL,
    cidade             VARCHAR(100) NOT NULL,
    estado             CHAR(2)      NOT NULL,
    referencia         VARCHAR(150),
    endereco_principal BOOLEAN      NOT NULL DEFAULT FALSE,
    -- permite que PEDIDO referencie (endereço, cliente) e garanta que o endereço é do cliente
    CONSTRAINT uq_endereco_id_usuario UNIQUE (id_endereco, id_usuario),
    CONSTRAINT ck_endereco_cep CHECK (cep ~ '^[0-9]{8}$'),
    CONSTRAINT ck_endereco_estado CHECK (estado ~ '^[A-Z]{2}$')
);
-- no máximo um endereço principal por usuário
CREATE UNIQUE INDEX uq_endereco_principal ON endereco (id_usuario) WHERE endereco_principal;

CREATE TABLE telefone (
    id_telefone INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_usuario  INTEGER     NOT NULL REFERENCES usuario (id_usuario) ON DELETE CASCADE,
    numero      VARCHAR(20) NOT NULL,
    tipo        VARCHAR(20) NOT NULL,
    principal   BOOLEAN     NOT NULL DEFAULT FALSE,
    CONSTRAINT ck_telefone_tipo CHECK (tipo IN ('CELULAR', 'COMERCIAL', 'RESIDENCIAL')),
    CONSTRAINT ck_telefone_numero CHECK (numero ~ '^[0-9+() -]{8,20}$')
);
CREATE UNIQUE INDEX uq_telefone_principal ON telefone (id_usuario) WHERE principal;

-- =============================================================================
-- CATÁLOGO, MATERIAIS E FORNECEDORES
-- =============================================================================
CREATE TABLE fornecedor (
    id_fornecedor INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome          VARCHAR(120) NOT NULL,
    nome_empresa  VARCHAR(150),
    cpf_cnpj      VARCHAR(14),
    email         VARCHAR(150),
    telefone      VARCHAR(20),
    endereco      VARCHAR(200),
    status        BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_fornecedor_cpf_cnpj UNIQUE (cpf_cnpj),
    CONSTRAINT ck_fornecedor_cpf_cnpj CHECK (cpf_cnpj IS NULL OR cpf_cnpj ~ '^([0-9]{11}|[0-9]{14})$')
);

CREATE TABLE categoria (
    id_categoria INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome         VARCHAR(80) NOT NULL,
    descricao    TEXT,
    status       BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_categoria_nome UNIQUE (nome)
);

CREATE TABLE produto (
    id_produto             INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_categoria           INTEGER      NOT NULL REFERENCES categoria (id_categoria),
    id_gerente             INTEGER      NOT NULL REFERENCES gerente (id_usuario),
    nome                   VARCHAR(120) NOT NULL,
    descricao              TEXT,
    preco                  NUMERIC(10,2) NOT NULL,
    permite_encomenda      BOOLEAN   NOT NULL DEFAULT TRUE,
    permite_personalizacao BOOLEAN   NOT NULL DEFAULT FALSE,
    ativo                  BOOLEAN   NOT NULL DEFAULT TRUE,
    data_cadastro          TIMESTAMP NOT NULL DEFAULT now(),
    CONSTRAINT ck_produto_preco CHECK (preco >= 0)
);

CREATE TABLE material (
    id_material    INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome           VARCHAR(120) NOT NULL,
    descricao      TEXT,
    unidade_medida VARCHAR(20)  NOT NULL,
    custo_unitario NUMERIC(10,2) NOT NULL,
    CONSTRAINT ck_material_custo CHECK (custo_unitario >= 0)
);

CREATE TABLE fornecedor_material (
    id_fornecedor      INTEGER NOT NULL REFERENCES fornecedor (id_fornecedor),
    id_material        INTEGER NOT NULL REFERENCES material (id_material),
    preco_fornecimento NUMERIC(10,2) NOT NULL,
    PRIMARY KEY (id_fornecedor, id_material),
    CONSTRAINT ck_fornecedor_material_preco CHECK (preco_fornecimento >= 0)
);

CREATE TABLE produto_material (
    id_produto           INTEGER NOT NULL REFERENCES produto (id_produto),
    id_material          INTEGER NOT NULL REFERENCES material (id_material),
    quantidade_utilizada NUMERIC(10,3) NOT NULL,
    PRIMARY KEY (id_produto, id_material),
    CONSTRAINT ck_produto_material_qtd CHECK (quantidade_utilizada > 0)
);

-- =============================================================================
-- ESTOQUES
-- =============================================================================
CREATE TABLE estoque_produto (
    id_estoque_produto    INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_produto            INTEGER NOT NULL REFERENCES produto (id_produto),
    quantidade_disponivel INTEGER NOT NULL DEFAULT 0,
    quantidade_reservada  INTEGER NOT NULL DEFAULT 0,
    ultima_atualizacao    TIMESTAMP NOT NULL DEFAULT now(),
    CONSTRAINT uq_estoque_produto UNIQUE (id_produto),
    CONSTRAINT ck_estoque_produto_disp CHECK (quantidade_disponivel >= 0),
    CONSTRAINT ck_estoque_produto_res CHECK (quantidade_reservada >= 0)
);

CREATE TABLE estoque_material (
    id_estoque_material   INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_material           INTEGER NOT NULL REFERENCES material (id_material),
    quantidade_disponivel NUMERIC(10,3) NOT NULL DEFAULT 0,
    estoque_minimo        NUMERIC(10,3) NOT NULL DEFAULT 0,
    ultima_atualizacao    TIMESTAMP NOT NULL DEFAULT now(),
    CONSTRAINT uq_estoque_material UNIQUE (id_material),
    CONSTRAINT ck_estoque_material_disp CHECK (quantidade_disponivel >= 0),
    CONSTRAINT ck_estoque_material_min CHECK (estoque_minimo >= 0)
);

-- =============================================================================
-- ENCOMENDAS, PEDIDOS E PRODUÇÃO
-- =============================================================================
CREATE TABLE solicitacao_encomenda (
    id_solicitacao           INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_cliente               INTEGER NOT NULL REFERENCES cliente (id_usuario),
    id_produto               INTEGER REFERENCES produto (id_produto),
    quantidade               INTEGER NOT NULL,
    descricao_personalizacao TEXT,
    finalidade               VARCHAR(150),
    data_evento              DATE,
    data_solicitacao         TIMESTAMP NOT NULL DEFAULT now(),
    status                   VARCHAR(30) NOT NULL DEFAULT 'EM_NEGOCIACAO',
    CONSTRAINT ck_solicitacao_qtd CHECK (quantidade > 0),
    CONSTRAINT ck_solicitacao_status CHECK (status IN ('EM_NEGOCIACAO', 'APROVADA', 'RECUSADA', 'CANCELADA'))
);

CREATE TABLE pedido (
    id_pedido           INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_cliente          INTEGER NOT NULL REFERENCES cliente (id_usuario),
    id_endereco         INTEGER,            -- NULL = retirada pelo cliente
    id_solicitacao      INTEGER,            -- preenchido quando o pedido nasce de uma encomenda aprovada
    data_pedido         TIMESTAMP NOT NULL DEFAULT now(),
    -- cópia dos dados de entrega no momento da compra (preserva o histórico)
    entrega_destinatario VARCHAR(120),
    entrega_cep          VARCHAR(8),
    entrega_logradouro   VARCHAR(150),
    entrega_numero       VARCHAR(15),
    entrega_complemento  VARCHAR(100),
    entrega_bairro       VARCHAR(100),
    entrega_cidade       VARCHAR(100),
    entrega_estado       CHAR(2),
    entrega_referencia   VARCHAR(150),
    tipo_pedido         VARCHAR(20) NOT NULL,
    status              VARCHAR(30) NOT NULL DEFAULT 'AGUARDANDO_PAGAMENTO',
    valor_total         NUMERIC(10,2) NOT NULL DEFAULT 0,
    CONSTRAINT uq_pedido_solicitacao UNIQUE (id_solicitacao),
    -- o endereço do pedido precisa pertencer ao cliente que fez o pedido
    CONSTRAINT fk_pedido_endereco_cliente FOREIGN KEY (id_endereco, id_cliente)
        REFERENCES endereco (id_endereco, id_usuario),
    CONSTRAINT fk_pedido_solicitacao FOREIGN KEY (id_solicitacao)
        REFERENCES solicitacao_encomenda (id_solicitacao),
    CONSTRAINT ck_pedido_tipo CHECK (tipo_pedido IN ('ECOMMERCE', 'ENCOMENDA')),
    CONSTRAINT ck_pedido_status CHECK (status IN ('AGUARDANDO_PAGAMENTO', 'PAGO', 'EM_PRODUCAO',
                                                  'PRONTO_ENVIO', 'ENVIADO', 'ENTREGUE', 'CANCELADO')),
    CONSTRAINT ck_pedido_valor CHECK (valor_total >= 0),
    CONSTRAINT ck_pedido_encomenda_solicitacao CHECK (tipo_pedido = 'ENCOMENDA' OR id_solicitacao IS NULL)
);
CREATE INDEX ix_pedido_cliente ON pedido (id_cliente);
CREATE INDEX ix_pedido_status ON pedido (status);

CREATE TABLE item_pedido (
    id_item                   INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_pedido                 INTEGER NOT NULL REFERENCES pedido (id_pedido) ON DELETE CASCADE,
    id_produto                INTEGER NOT NULL REFERENCES produto (id_produto),
    quantidade                INTEGER NOT NULL,
    preco_unitario            NUMERIC(10,2) NOT NULL,
    observacao_personalizacao TEXT,
    CONSTRAINT ck_item_pedido_qtd CHECK (quantidade > 0),
    CONSTRAINT ck_item_pedido_preco CHECK (preco_unitario >= 0)
);
CREATE INDEX ix_item_pedido_pedido ON item_pedido (id_pedido);

CREATE TABLE producao (
    id_producao    INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_pedido      INTEGER REFERENCES pedido (id_pedido),
    id_produto     INTEGER NOT NULL REFERENCES produto (id_produto),
    tipo_producao  VARCHAR(20) NOT NULL,
    id_fabricante  INTEGER NOT NULL REFERENCES fabricante (id_usuario),
    id_gerente     INTEGER NOT NULL REFERENCES gerente (id_usuario),
    quantidade     INTEGER NOT NULL,
    data_inicio    TIMESTAMP,
    data_conclusao TIMESTAMP,
    status         VARCHAR(30) NOT NULL DEFAULT 'AGUARDANDO',
    CONSTRAINT ck_producao_tipo CHECK (tipo_producao IN ('PEDIDO', 'REPOSICAO')),
    -- origem coerente: PEDIDO exige id_pedido; REPOSICAO não pode ter pedido
    CONSTRAINT ck_producao_origem CHECK (
        (tipo_producao = 'PEDIDO'    AND id_pedido IS NOT NULL) OR
        (tipo_producao = 'REPOSICAO' AND id_pedido IS NULL)),
    CONSTRAINT ck_producao_qtd CHECK (quantidade > 0),
    CONSTRAINT ck_producao_status CHECK (status IN ('AGUARDANDO', 'EM_ANDAMENTO', 'CONCLUIDA', 'CANCELADA')),
    CONSTRAINT ck_producao_datas CHECK (data_conclusao IS NULL OR data_inicio IS NULL OR data_conclusao >= data_inicio)
);
CREATE INDEX ix_producao_pedido ON producao (id_pedido);
CREATE INDEX ix_producao_fabricante ON producao (id_fabricante);

-- =============================================================================
-- PAGAMENTOS
-- =============================================================================
CREATE TABLE forma_pagamento (
    id_forma_pagamento INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    descricao          VARCHAR(30) NOT NULL,
    CONSTRAINT uq_forma_pagamento_desc UNIQUE (descricao),
    CONSTRAINT ck_forma_pagamento_desc CHECK (descricao IN ('PIX', 'CARTAO', 'BOLETO'))
);

CREATE TABLE cartao (
    id_cartao              INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_cliente             INTEGER NOT NULL REFERENCES cliente (id_usuario) ON DELETE CASCADE,
    bandeira               VARCHAR(30) NOT NULL,
    ultimos_quatro_digitos CHAR(4) NOT NULL,
    token_referencia       VARCHAR(255),   -- somente referência segura do provedor; nunca número completo/CVV
    validade               DATE,
    CONSTRAINT ck_cartao_bandeira CHECK (bandeira IN ('VISA', 'MASTERCARD', 'ELO', 'AMEX', 'HIPERCARD')),
    CONSTRAINT ck_cartao_digitos CHECK (ultimos_quatro_digitos ~ '^[0-9]{4}$')
);

CREATE TABLE pagamento (
    id_pagamento            INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_pedido               INTEGER NOT NULL REFERENCES pedido (id_pedido),
    id_forma_pagamento      INTEGER NOT NULL REFERENCES forma_pagamento (id_forma_pagamento),
    id_cartao               INTEGER REFERENCES cartao (id_cartao),
    valor                   NUMERIC(10,2) NOT NULL,
    data_pagamento          TIMESTAMP,
    vencimento              DATE,
    identificador_transacao VARCHAR(150),
    status                  VARCHAR(30) NOT NULL DEFAULT 'PENDENTE',
    CONSTRAINT ck_pagamento_valor CHECK (valor > 0),
    CONSTRAINT ck_pagamento_status CHECK (status IN ('PENDENTE', 'APROVADO', 'RECUSADO', 'CANCELADO')),
    CONSTRAINT ck_pagamento_aprovado_data CHECK (status <> 'APROVADO' OR data_pagamento IS NOT NULL)
);
-- várias tentativas são permitidas, mas somente UMA pode ser aprovada por pedido
CREATE UNIQUE INDEX uq_pagamento_um_aprovado_por_pedido ON pagamento (id_pedido) WHERE status = 'APROVADO';
CREATE INDEX ix_pagamento_pedido ON pagamento (id_pedido);

-- =============================================================================
-- LOGÍSTICA E HISTÓRICO
-- =============================================================================
CREATE TABLE transportadora (
    id_transportadora INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome              VARCHAR(120) NOT NULL,
    cnpj              VARCHAR(14),
    telefone          VARCHAR(20),
    email             VARCHAR(150),
    CONSTRAINT uq_transportadora_cnpj UNIQUE (cnpj),
    CONSTRAINT ck_transportadora_cnpj CHECK (cnpj IS NULL OR cnpj ~ '^[0-9]{14}$')
);

CREATE TABLE entrega (
    id_entrega        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_pedido         INTEGER NOT NULL REFERENCES pedido (id_pedido),
    id_transportadora INTEGER REFERENCES transportadora (id_transportadora),
    codigo_rastreio   VARCHAR(100),
    modalidade        VARCHAR(30) NOT NULL,
    data_envio        TIMESTAMP,
    previsao_entrega  DATE,
    data_entrega      TIMESTAMP,
    status            VARCHAR(30) NOT NULL DEFAULT 'PREPARANDO',
    CONSTRAINT uq_entrega_pedido UNIQUE (id_pedido),   -- no máximo uma entrega por pedido
    CONSTRAINT ck_entrega_modalidade CHECK (modalidade IN ('CORREIOS', 'TRANSPORTADORA', 'ENTREGA_PROPRIA', 'RETIRADA')),
    CONSTRAINT ck_entrega_status CHECK (status IN ('PREPARANDO', 'ENVIADO', 'ENTREGUE', 'DISPONIVEL_RETIRADA', 'RETIRADO', 'CANCELADA')),
    -- transportadora só quando a modalidade for TRANSPORTADORA
    CONSTRAINT ck_entrega_transportadora CHECK (
        (modalidade = 'TRANSPORTADORA' AND id_transportadora IS NOT NULL) OR
        (modalidade <> 'TRANSPORTADORA' AND id_transportadora IS NULL)),
    -- status de retirada só para a modalidade RETIRADA
    CONSTRAINT ck_entrega_status_retirada CHECK (
        status NOT IN ('DISPONIVEL_RETIRADA', 'RETIRADO') OR modalidade = 'RETIRADA')
);

CREATE TABLE historico_pedido (
    id_historico    INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_pedido       INTEGER NOT NULL REFERENCES pedido (id_pedido) ON DELETE CASCADE,
    status_anterior VARCHAR(30),
    status_novo     VARCHAR(30) NOT NULL,
    data_alteracao  TIMESTAMP NOT NULL DEFAULT now(),
    descricao       TEXT
);
CREATE INDEX ix_historico_pedido ON historico_pedido (id_pedido);

-- =============================================================================
-- CARRINHO
-- =============================================================================
CREATE TABLE carrinho (
    id_carrinho  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_cliente   INTEGER NOT NULL REFERENCES cliente (id_usuario) ON DELETE CASCADE,
    data_criacao TIMESTAMP NOT NULL DEFAULT now(),
    status       VARCHAR(20) NOT NULL DEFAULT 'ABERTO',
    CONSTRAINT ck_carrinho_status CHECK (status IN ('ABERTO', 'CONVERTIDO', 'ABANDONADO'))
);
-- cada cliente pode ter no máximo um carrinho ABERTO
CREATE UNIQUE INDEX uq_carrinho_um_aberto_por_cliente ON carrinho (id_cliente) WHERE status = 'ABERTO';

CREATE TABLE item_carrinho (
    id_carrinho INTEGER NOT NULL REFERENCES carrinho (id_carrinho) ON DELETE CASCADE,
    id_produto  INTEGER NOT NULL REFERENCES produto (id_produto),
    quantidade  INTEGER NOT NULL,
    PRIMARY KEY (id_carrinho, id_produto),
    CONSTRAINT ck_item_carrinho_qtd CHECK (quantidade > 0)
);

-- Dados fixos
INSERT INTO forma_pagamento (descricao) VALUES ('PIX'), ('CARTAO'), ('BOLETO');