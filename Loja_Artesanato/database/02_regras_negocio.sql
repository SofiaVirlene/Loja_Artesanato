-- =============================================================================
-- LOJA VIRTUAL DE ARTESANATO - Banco de Dados II (IFPI - Campus Picos)
-- Arquivo 2 de 3: REGRAS DE NEGÓCIO (Function, Procedures e Triggers)
-- Execute depois de 01_estrutura.sql
--
-- Resumo:
--   FUNCTION   fn_valor_total_pedido ......... calcula o total de um pedido
--              fn_reserva_expirada ........... aplica a regra de expiração (30 min / vencimento do boleto)
--              fn_autenticar_usuario ......... confere e-mail e senha (hash)
--   PROCEDURE  sp_cadastrar_usuario .......... cria usuário + perfil na mesma transação
--              sp_finalizar_pedido ........... carrinho -> pedido, com reserva de estoque
--              sp_registrar_pagamento ........ cria tentativa de pagamento (valor integral)
--              sp_aprovar_pagamento .......... aprova, consome a reserva e marca o pedido como PAGO
--              sp_recusar_pagamento .......... registra tentativa recusada
--              sp_cancelar_pedido ............ cancela e devolve a reserva ao estoque
--              sp_expirar_reservas ........... rotina agendada: cancela pedidos vencidos
--              sp_aprovar_encomenda .......... transforma solicitação aprovada em pedido
--   TRIGGER    histórico de status, transições válidas, especialização total de USUARIO,
--              pedido com itens, validações de pagamento/entrega, produção concluída
-- =============================================================================

-- =============================================================================
-- 1) FUNCTIONS
-- =============================================================================

-- Total do pedido = soma de quantidade x preço unitário dos itens
CREATE OR REPLACE FUNCTION fn_valor_total_pedido(p_id_pedido INTEGER)
RETURNS NUMERIC(10,2)
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(SUM(quantidade * preco_unitario), 0)::NUMERIC(10,2)
    FROM item_pedido
    WHERE id_pedido = p_id_pedido;
$$;

-- Regra de expiração da reserva (somente pedidos ECOMMERCE aguardando pagamento):
--   * com boleto pendente: expira quando TODOS os boletos pendentes já venceram;
--   * sem boleto pendente (Pix/cartão): expira 30 minutos após a criação do pedido.
CREATE OR REPLACE FUNCTION fn_reserva_expirada(p_id_pedido INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_pedido   pedido%ROWTYPE;
    v_boletos  INTEGER;
    v_vigentes INTEGER;
BEGIN
    SELECT * INTO v_pedido FROM pedido WHERE id_pedido = p_id_pedido;
    IF NOT FOUND OR v_pedido.tipo_pedido <> 'ECOMMERCE' OR v_pedido.status <> 'AGUARDANDO_PAGAMENTO' THEN
        RETURN FALSE;
    END IF;

    SELECT COUNT(*), COUNT(*) FILTER (WHERE pg.vencimento >= CURRENT_DATE)
      INTO v_boletos, v_vigentes
      FROM pagamento pg
      JOIN forma_pagamento f ON f.id_forma_pagamento = pg.id_forma_pagamento
     WHERE pg.id_pedido = p_id_pedido AND f.descricao = 'BOLETO' AND pg.status = 'PENDENTE';

    IF v_boletos > 0 THEN
        RETURN v_vigentes = 0;
    END IF;
    RETURN v_pedido.data_pedido < now() - INTERVAL '30 minutes';
END;
$$;

-- Autenticação: devolve o id do usuário ativo ou NULL
CREATE OR REPLACE FUNCTION fn_autenticar_usuario(p_email VARCHAR, p_senha VARCHAR)
RETURNS INTEGER
LANGUAGE sql STABLE
AS $$
    SELECT id_usuario
      FROM usuario
     WHERE email = p_email AND status AND senha_hash = crypt(p_senha, senha_hash);
$$;

-- Função interna: devolve ao estoque as unidades reservadas de um pedido ECOMMERCE
CREATE OR REPLACE FUNCTION fn_liberar_reserva(p_id_pedido INTEGER)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT id_produto, quantidade FROM item_pedido
              WHERE id_pedido = p_id_pedido ORDER BY id_produto LOOP
        UPDATE estoque_produto
           SET quantidade_reservada  = quantidade_reservada - r.quantidade,
               quantidade_disponivel = quantidade_disponivel + r.quantidade
         WHERE id_produto = r.id_produto;
    END LOOP;
END;
$$;

-- Função interna: consome a reserva (as unidades já saíram do disponível na reserva)
CREATE OR REPLACE FUNCTION fn_consumir_reserva(p_id_pedido INTEGER)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT id_produto, quantidade FROM item_pedido
              WHERE id_pedido = p_id_pedido ORDER BY id_produto LOOP
        UPDATE estoque_produto
           SET quantidade_reservada = quantidade_reservada - r.quantidade
         WHERE id_produto = r.id_produto;
    END LOOP;
END;
$$;

-- =============================================================================
-- 2) TRIGGERS
-- =============================================================================

-- 2.1 Data da última atualização dos estoques ---------------------------------
CREATE OR REPLACE FUNCTION trg_estoque_atualizacao()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.ultima_atualizacao := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_estoque_produto_atualizacao BEFORE UPDATE ON estoque_produto
    FOR EACH ROW EXECUTE FUNCTION trg_estoque_atualizacao();
CREATE TRIGGER trg_estoque_material_atualizacao BEFORE UPDATE ON estoque_material
    FOR EACH ROW EXECUTE FUNCTION trg_estoque_atualizacao();

-- 2.2 Especialização TOTAL de USUARIO ------------------------------------------
-- (a disjunção já é garantida pela chave estrangeira composta com tipo_usuario)
-- Ao final da transação, todo usuário precisa ter a linha do seu perfil.
CREATE OR REPLACE FUNCTION trg_verifica_especializacao()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_id   INTEGER;
    v_tipo VARCHAR(20);
    v_ok   BOOLEAN;
BEGIN
    v_id := CASE WHEN TG_TABLE_NAME = 'usuario' THEN NEW.id_usuario ELSE OLD.id_usuario END;
    SELECT tipo_usuario INTO v_tipo FROM usuario WHERE id_usuario = v_id;
    IF NOT FOUND THEN
        RETURN NULL;   -- usuário removido junto com o perfil: ok
    END IF;

    v_ok := CASE v_tipo
        WHEN 'CLIENTE'    THEN EXISTS (SELECT 1 FROM cliente    WHERE id_usuario = v_id)
        WHEN 'GERENTE'    THEN EXISTS (SELECT 1 FROM gerente    WHERE id_usuario = v_id)
        WHEN 'FABRICANTE' THEN EXISTS (SELECT 1 FROM fabricante WHERE id_usuario = v_id)
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'Usuário % (%) não possui o registro do perfil correspondente. Use sp_cadastrar_usuario.', v_id, v_tipo
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_usuario_especializacao_total
    AFTER INSERT OR UPDATE OF tipo_usuario ON usuario
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION trg_verifica_especializacao();
CREATE CONSTRAINT TRIGGER trg_cliente_especializacao_total
    AFTER DELETE ON cliente DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION trg_verifica_especializacao();
CREATE CONSTRAINT TRIGGER trg_gerente_especializacao_total
    AFTER DELETE ON gerente DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION trg_verifica_especializacao();
CREATE CONSTRAINT TRIGGER trg_fabricante_especializacao_total
    AFTER DELETE ON fabricante DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION trg_verifica_especializacao();

-- 2.3 Pedido: transições de status válidas -------------------------------------
CREATE OR REPLACE FUNCTION trg_pedido_transicao_status()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;
    IF NOT ((OLD.status, NEW.status) IN (
            ('AGUARDANDO_PAGAMENTO', 'PAGO'),
            ('AGUARDANDO_PAGAMENTO', 'CANCELADO'),
            ('PAGO',                 'EM_PRODUCAO'),
            ('PAGO',                 'PRONTO_ENVIO'),
            ('EM_PRODUCAO',          'PRONTO_ENVIO'),
            ('PRONTO_ENVIO',         'ENVIADO'),
            ('PRONTO_ENVIO',         'ENTREGUE'),   -- retirada presencial
            ('ENVIADO',              'ENTREGUE'))) THEN
        RAISE EXCEPTION 'Transição de status inválida no pedido %: % -> %', OLD.id_pedido, OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_pedido_transicao BEFORE UPDATE OF status ON pedido
    FOR EACH ROW EXECUTE FUNCTION trg_pedido_transicao_status();

-- 2.4 Pedido: histórico automático de alterações de status ----------------------
-- O motivo pode ser informado com: SELECT set_config('app.motivo', 'texto', true);
CREATE OR REPLACE FUNCTION trg_pedido_historico()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_motivo TEXT := NULLIF(current_setting('app.motivo', TRUE), '');
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO historico_pedido (id_pedido, status_anterior, status_novo, descricao)
        VALUES (NEW.id_pedido, NULL, NEW.status, COALESCE(v_motivo, 'Pedido criado'));
    ELSIF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO historico_pedido (id_pedido, status_anterior, status_novo, descricao)
        VALUES (NEW.id_pedido, OLD.status, NEW.status, COALESCE(v_motivo, 'Alteração de status'));
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_pedido_historico_ins_upd AFTER INSERT OR UPDATE OF status ON pedido
    FOR EACH ROW EXECUTE FUNCTION trg_pedido_historico();

-- 2.5 Pedido confirmado precisa ter ao menos um item (verificado no COMMIT) ------
CREATE OR REPLACE FUNCTION trg_pedido_exige_item()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_id     INTEGER;
    v_status VARCHAR(30);
BEGIN
    v_id := CASE WHEN TG_TABLE_NAME = 'pedido' THEN NEW.id_pedido ELSE OLD.id_pedido END;
    SELECT status INTO v_status FROM pedido WHERE id_pedido = v_id;
    IF FOUND AND v_status <> 'CANCELADO'
       AND NOT EXISTS (SELECT 1 FROM item_pedido WHERE id_pedido = v_id) THEN
        RAISE EXCEPTION 'O pedido % não possui itens.', v_id
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_pedido_com_itens
    AFTER INSERT OR UPDATE OF status ON pedido DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION trg_pedido_exige_item();
CREATE CONSTRAINT TRIGGER trg_item_pedido_remocao
    AFTER DELETE ON item_pedido DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION trg_pedido_exige_item();

-- 2.6 Pagamento: validações de forma, cartão e valor integral --------------------
CREATE OR REPLACE FUNCTION trg_pagamento_validar()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_forma   VARCHAR(30);
    v_pedido  pedido%ROWTYPE;
    v_cli_car INTEGER;
BEGIN
    SELECT descricao INTO v_forma FROM forma_pagamento WHERE id_forma_pagamento = NEW.id_forma_pagamento;
    SELECT * INTO v_pedido FROM pedido WHERE id_pedido = NEW.id_pedido;

    IF TG_OP = 'INSERT' AND v_pedido.status <> 'AGUARDANDO_PAGAMENTO' THEN
        RAISE EXCEPTION 'O pedido % não está aguardando pagamento (status: %).', v_pedido.id_pedido, v_pedido.status
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_forma = 'CARTAO' THEN
        IF NEW.id_cartao IS NULL THEN
            RAISE EXCEPTION 'Pagamento com cartão exige id_cartao.' USING ERRCODE = 'check_violation';
        END IF;
        SELECT id_cliente INTO v_cli_car FROM cartao WHERE id_cartao = NEW.id_cartao;
        IF v_cli_car IS DISTINCT FROM v_pedido.id_cliente THEN
            RAISE EXCEPTION 'O cartão % não pertence ao cliente do pedido %.', NEW.id_cartao, NEW.id_pedido
                USING ERRCODE = 'check_violation';
        END IF;
    ELSIF NEW.id_cartao IS NOT NULL THEN
        RAISE EXCEPTION 'Pagamentos em % não podem informar cartão.', v_forma USING ERRCODE = 'check_violation';
    END IF;

    IF v_forma = 'BOLETO' AND NEW.vencimento IS NULL THEN
        RAISE EXCEPTION 'Boleto exige data de vencimento.' USING ERRCODE = 'check_violation';
    END IF;

    -- pagamento integral: o valor aprovado precisa ser igual ao total do pedido
    IF NEW.status = 'APROVADO' AND NEW.valor <> v_pedido.valor_total THEN
        RAISE EXCEPTION 'Pagamento parcial não é permitido: valor % difere do total do pedido (%).', NEW.valor, v_pedido.valor_total
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_pagamento_validacao BEFORE INSERT OR UPDATE ON pagamento
    FOR EACH ROW EXECUTE FUNCTION trg_pagamento_validar();

-- 2.7 Produção: datas, baixa de materiais e destino do produto fabricado ----------
CREATE OR REPLACE FUNCTION trg_producao_datas()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status IN ('CONCLUIDA', 'CANCELADA') AND NEW.status <> OLD.status THEN
        RAISE EXCEPTION 'A produção % já está %.', OLD.id_producao, OLD.status USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status = 'EM_ANDAMENTO' AND NEW.data_inicio IS NULL THEN
        NEW.data_inicio := now();
    ELSIF NEW.status = 'CONCLUIDA' THEN
        NEW.data_inicio    := COALESCE(NEW.data_inicio, now());
        NEW.data_conclusao := COALESCE(NEW.data_conclusao, now());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_producao_datas BEFORE UPDATE OF status ON producao
    FOR EACH ROW EXECUTE FUNCTION trg_producao_datas();

CREATE OR REPLACE FUNCTION trg_producao_concluida()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
BEGIN
    IF NEW.status <> 'CONCLUIDA' OR OLD.status = 'CONCLUIDA' THEN
        RETURN NULL;
    END IF;

    -- 1) baixa dos materiais: composição do produto x quantidade fabricada
    FOR r IN SELECT pm.id_material, m.nome,
                    pm.quantidade_utilizada * NEW.quantidade AS necessario
               FROM produto_material pm
               JOIN material m ON m.id_material = pm.id_material
              WHERE pm.id_produto = NEW.id_produto
              ORDER BY pm.id_material LOOP
        UPDATE estoque_material
           SET quantidade_disponivel = quantidade_disponivel - r.necessario
         WHERE id_material = r.id_material AND quantidade_disponivel >= r.necessario;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Estoque insuficiente do material "%" para concluir a produção %.', r.nome, NEW.id_producao
                USING ERRCODE = 'check_violation';
        END IF;
    END LOOP;

    -- 2) destino do produto fabricado
    IF NEW.tipo_producao = 'REPOSICAO' THEN
        INSERT INTO estoque_produto (id_produto, quantidade_disponivel)
        VALUES (NEW.id_produto, NEW.quantidade)
        ON CONFLICT (id_produto)
        DO UPDATE SET quantidade_disponivel = estoque_produto.quantidade_disponivel + EXCLUDED.quantidade_disponivel;
    ELSE
        -- produção de PEDIDO (inclui encomendas): o produto é destinado ao pedido e NÃO entra no estoque
        IF NOT EXISTS (SELECT 1 FROM producao
                        WHERE id_pedido = NEW.id_pedido AND status NOT IN ('CONCLUIDA', 'CANCELADA')) THEN
            UPDATE pedido SET status = 'PRONTO_ENVIO'
             WHERE id_pedido = NEW.id_pedido AND status = 'EM_PRODUCAO';
        END IF;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_producao_concluida AFTER UPDATE OF status ON producao
    FOR EACH ROW EXECUTE FUNCTION trg_producao_concluida();

-- Produção de pedido iniciada: pedido pago passa para EM_PRODUCAO
CREATE OR REPLACE FUNCTION trg_producao_inicio_pedido()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.tipo_producao = 'PEDIDO' THEN
        UPDATE pedido SET status = 'EM_PRODUCAO'
         WHERE id_pedido = NEW.id_pedido AND status = 'PAGO';
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_producao_inicio_pedido AFTER INSERT ON producao
    FOR EACH ROW EXECUTE FUNCTION trg_producao_inicio_pedido();

-- 2.8 Entrega: validações e reflexo no status do pedido ----------------------------
CREATE OR REPLACE FUNCTION trg_entrega_validar()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_pedido pedido%ROWTYPE;
BEGIN
    SELECT * INTO v_pedido FROM pedido WHERE id_pedido = NEW.id_pedido;
    IF TG_OP = 'INSERT' AND v_pedido.status NOT IN ('PAGO', 'PRONTO_ENVIO') THEN
        RAISE EXCEPTION 'O pedido % ainda não está pronto para envio ou retirada (status: %).', v_pedido.id_pedido, v_pedido.status
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.modalidade <> 'RETIRADA' AND v_pedido.entrega_logradouro IS NULL THEN
        RAISE EXCEPTION 'O pedido % não possui endereço de entrega; use a modalidade RETIRADA.', v_pedido.id_pedido
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_entrega_validacao BEFORE INSERT OR UPDATE ON entrega
    FOR EACH ROW EXECUTE FUNCTION trg_entrega_validar();

CREATE OR REPLACE FUNCTION trg_entrega_reflexo_pedido()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_alvo   VARCHAR(30);
    v_status VARCHAR(30);
BEGIN
    v_alvo := CASE NEW.status
        WHEN 'DISPONIVEL_RETIRADA' THEN 'PRONTO_ENVIO'
        WHEN 'ENVIADO'             THEN 'ENVIADO'
        WHEN 'ENTREGUE'            THEN 'ENTREGUE'
        WHEN 'RETIRADO'            THEN 'ENTREGUE'
    END;
    IF v_alvo IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT status INTO v_status FROM pedido WHERE id_pedido = NEW.id_pedido FOR UPDATE;
    IF v_status = 'PAGO' AND v_alvo <> 'PRONTO_ENVIO' THEN
        UPDATE pedido SET status = 'PRONTO_ENVIO' WHERE id_pedido = NEW.id_pedido;   -- passo intermediário
    END IF;
    UPDATE pedido SET status = v_alvo WHERE id_pedido = NEW.id_pedido AND status <> v_alvo;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_entrega_reflexo AFTER INSERT OR UPDATE OF status ON entrega
    FOR EACH ROW EXECUTE FUNCTION trg_entrega_reflexo_pedido();

-- =============================================================================
-- 3) PROCEDURES (cada CALL roda em uma única transação: tudo ou nada)
-- =============================================================================

-- 3.1 Cadastro de usuário + perfil -------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_cadastrar_usuario(
    p_nome            VARCHAR,
    p_email           VARCHAR,
    p_senha           VARCHAR,
    p_tipo            VARCHAR,
    p_cpf             VARCHAR DEFAULT NULL,
    p_data_nascimento DATE    DEFAULT NULL,
    p_nivel_acesso    VARCHAR DEFAULT 'BASICO',
    p_especialidade   VARCHAR DEFAULT NULL,
    INOUT p_id_usuario INTEGER DEFAULT NULL)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_senha IS NULL OR length(p_senha) < 8 THEN
        RAISE EXCEPTION 'A senha deve ter pelo menos 8 caracteres.';
    END IF;

    INSERT INTO usuario (nome, email, senha_hash, tipo_usuario)
    VALUES (p_nome, p_email, crypt(p_senha, gen_salt('bf')), p_tipo)
    RETURNING id_usuario INTO p_id_usuario;

    IF p_tipo = 'CLIENTE' THEN
        INSERT INTO cliente (id_usuario, cpf, data_nascimento) VALUES (p_id_usuario, p_cpf, p_data_nascimento);
    ELSIF p_tipo = 'GERENTE' THEN
        INSERT INTO gerente (id_usuario, nivel_acesso) VALUES (p_id_usuario, p_nivel_acesso);
    ELSIF p_tipo = 'FABRICANTE' THEN
        INSERT INTO fabricante (id_usuario, especialidade) VALUES (p_id_usuario, p_especialidade);
    END IF;
END;
$$;

-- 3.2 Finalização do pedido: carrinho -> pedido + itens + reserva de estoque --------
-- p_id_endereco NULL = retirada pelo cliente. O CPF é exigido aqui (checkout).
CREATE OR REPLACE PROCEDURE sp_finalizar_pedido(
    p_id_carrinho INTEGER,
    p_id_endereco INTEGER DEFAULT NULL,
    p_cpf         VARCHAR DEFAULT NULL,
    INOUT p_id_pedido INTEGER DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_car  carrinho%ROWTYPE;
    v_cpf  VARCHAR(11);
    v_end  endereco%ROWTYPE;
    v_nome VARCHAR(120);
    r      RECORD;
BEGIN
    SELECT * INTO v_car FROM carrinho WHERE id_carrinho = p_id_carrinho FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Carrinho % não encontrado.', p_id_carrinho;
    END IF;
    IF v_car.status <> 'ABERTO' THEN
        RAISE EXCEPTION 'O carrinho % não está aberto (status: %).', p_id_carrinho, v_car.status;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM item_carrinho WHERE id_carrinho = p_id_carrinho) THEN
        RAISE EXCEPTION 'O carrinho % está vazio.', p_id_carrinho;
    END IF;

    -- CPF: opcional no cadastro, obrigatório no checkout
    SELECT cpf INTO v_cpf FROM cliente WHERE id_usuario = v_car.id_cliente;
    IF v_cpf IS NULL THEN
        IF p_cpf IS NULL THEN
            RAISE EXCEPTION 'Informe o CPF para finalizar a compra.';
        END IF;
        UPDATE cliente SET cpf = p_cpf WHERE id_usuario = v_car.id_cliente;  -- CHECK valida o CPF
    END IF;

    IF p_id_endereco IS NOT NULL THEN
        SELECT * INTO v_end FROM endereco WHERE id_endereco = p_id_endereco AND id_usuario = v_car.id_cliente;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'O endereço % não pertence ao cliente do carrinho.', p_id_endereco;
        END IF;
    END IF;
    SELECT nome INTO v_nome FROM usuario WHERE id_usuario = v_car.id_cliente;

    -- reserva do estoque (em ordem de produto, para evitar deadlocks entre clientes)
    FOR r IN SELECT ic.id_produto, ic.quantidade, p.nome, p.ativo
               FROM item_carrinho ic
               JOIN produto p ON p.id_produto = ic.id_produto
              WHERE ic.id_carrinho = p_id_carrinho
              ORDER BY ic.id_produto LOOP
        IF NOT r.ativo THEN
            RAISE EXCEPTION 'O produto "%" não está disponível.', r.nome;
        END IF;
        UPDATE estoque_produto
           SET quantidade_disponivel = quantidade_disponivel - r.quantidade,
               quantidade_reservada  = quantidade_reservada  + r.quantidade
         WHERE id_produto = r.id_produto AND quantidade_disponivel >= r.quantidade;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Estoque insuficiente para "%". Reduza a quantidade ou faça uma solicitação de encomenda.', r.nome
                USING ERRCODE = 'check_violation';
        END IF;
    END LOOP;

    INSERT INTO pedido (id_cliente, id_endereco, tipo_pedido,
                        entrega_destinatario, entrega_cep, entrega_logradouro, entrega_numero,
                        entrega_complemento, entrega_bairro, entrega_cidade, entrega_estado, entrega_referencia)
    VALUES (v_car.id_cliente, p_id_endereco, 'ECOMMERCE',
            CASE WHEN p_id_endereco IS NOT NULL THEN v_nome END,
            v_end.cep, v_end.logradouro, v_end.numero,
            v_end.complemento, v_end.bairro, v_end.cidade, v_end.estado, v_end.referencia)
    RETURNING id_pedido INTO p_id_pedido;

    INSERT INTO item_pedido (id_pedido, id_produto, quantidade, preco_unitario)
    SELECT p_id_pedido, ic.id_produto, ic.quantidade, p.preco   -- preço congelado no momento da compra
      FROM item_carrinho ic
      JOIN produto p ON p.id_produto = ic.id_produto
     WHERE ic.id_carrinho = p_id_carrinho;

    UPDATE pedido SET valor_total = fn_valor_total_pedido(p_id_pedido) WHERE id_pedido = p_id_pedido;
    UPDATE carrinho SET status = 'CONVERTIDO' WHERE id_carrinho = p_id_carrinho;
END;
$$;

-- 3.3 Registro de tentativa de pagamento (sempre pelo valor integral do pedido) -----
CREATE OR REPLACE PROCEDURE sp_registrar_pagamento(
    p_id_pedido  INTEGER,
    p_forma      VARCHAR,                -- 'PIX', 'CARTAO' ou 'BOLETO'
    p_id_cartao  INTEGER DEFAULT NULL,
    p_vencimento DATE    DEFAULT NULL,   -- boleto: padrão = hoje + 3 dias
    INOUT p_id_pagamento INTEGER DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_pedido pedido%ROWTYPE;
    v_forma  INTEGER;
BEGIN
    SELECT * INTO v_pedido FROM pedido WHERE id_pedido = p_id_pedido FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pedido % não encontrado.', p_id_pedido;
    END IF;
    IF v_pedido.status <> 'AGUARDANDO_PAGAMENTO' THEN
        RAISE EXCEPTION 'O pedido % não está aguardando pagamento (status: %).', p_id_pedido, v_pedido.status;
    END IF;

    SELECT id_forma_pagamento INTO v_forma FROM forma_pagamento WHERE descricao = upper(p_forma);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Forma de pagamento inválida: %.', p_forma;
    END IF;

    INSERT INTO pagamento (id_pedido, id_forma_pagamento, id_cartao, valor, vencimento, identificador_transacao)
    VALUES (p_id_pedido, v_forma, p_id_cartao, v_pedido.valor_total,
            CASE WHEN upper(p_forma) = 'BOLETO' THEN COALESCE(p_vencimento, CURRENT_DATE + 3) END,
            'SIM-' || upper(p_forma) || '-' || substr(md5(random()::TEXT), 1, 12))   -- simulação (sem provedor real)
    RETURNING id_pagamento INTO p_id_pagamento;
END;
$$;

-- 3.4 Aprovação do pagamento --------------------------------------------------------
-- Trava a linha do pedido para não competir com a expiração: se o pedido já foi
-- cancelado por vencimento, a aprovação é recusada e o estoque não é liberado duas vezes.
CREATE OR REPLACE PROCEDURE sp_aprovar_pagamento(p_id_pagamento INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_id_pedido INTEGER;
    v_pedido    pedido%ROWTYPE;
    v_status    VARCHAR(30);
BEGIN
    SELECT id_pedido INTO v_id_pedido FROM pagamento WHERE id_pagamento = p_id_pagamento;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pagamento % não encontrado.', p_id_pagamento;
    END IF;

    SELECT * INTO v_pedido FROM pedido WHERE id_pedido = v_id_pedido FOR UPDATE;   -- bloqueio do pedido
    SELECT status INTO v_status FROM pagamento WHERE id_pagamento = p_id_pagamento FOR UPDATE;

    IF v_status <> 'PENDENTE' THEN
        RAISE EXCEPTION 'O pagamento % não está pendente (status: %).', p_id_pagamento, v_status;
    END IF;
    IF v_pedido.status <> 'AGUARDANDO_PAGAMENTO' THEN
        RAISE EXCEPTION 'O pedido % não aguarda pagamento (status: %). A reserva pode ter expirado.', v_id_pedido, v_pedido.status
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE pagamento SET status = 'APROVADO', data_pagamento = now()
     WHERE id_pagamento = p_id_pagamento;          -- trigger confere o valor integral
    UPDATE pagamento SET status = 'CANCELADO'
     WHERE id_pedido = v_id_pedido AND status = 'PENDENTE' AND id_pagamento <> p_id_pagamento;

    IF v_pedido.tipo_pedido = 'ECOMMERCE' THEN
        PERFORM fn_consumir_reserva(v_id_pedido);   -- unidades reservadas saem do estoque
    END IF;
    UPDATE pedido SET status = 'PAGO' WHERE id_pedido = v_id_pedido;
END;
$$;

CREATE OR REPLACE PROCEDURE sp_recusar_pagamento(p_id_pagamento INTEGER)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE pagamento SET status = 'RECUSADO' WHERE id_pagamento = p_id_pagamento AND status = 'PENDENTE';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pagamento % não encontrado ou não está pendente.', p_id_pagamento;
    END IF;
END;
$$;

-- 3.5 Cancelamento (somente enquanto aguarda pagamento) -------------------------------
CREATE OR REPLACE PROCEDURE sp_cancelar_pedido(p_id_pedido INTEGER, p_motivo TEXT DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_pedido pedido%ROWTYPE;
BEGIN
    SELECT * INTO v_pedido FROM pedido WHERE id_pedido = p_id_pedido FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pedido % não encontrado.', p_id_pedido;
    END IF;
    IF v_pedido.status <> 'AGUARDANDO_PAGAMENTO' THEN
        RAISE EXCEPTION 'O pedido % não pode ser cancelado por este procedimento (status: %).', p_id_pedido, v_pedido.status;
    END IF;

    IF v_pedido.tipo_pedido = 'ECOMMERCE' THEN
        PERFORM fn_liberar_reserva(p_id_pedido);    -- devolve as unidades ao estoque disponível
    END IF;
    UPDATE pagamento SET status = 'CANCELADO' WHERE id_pedido = p_id_pedido AND status = 'PENDENTE';

    PERFORM set_config('app.motivo', COALESCE(p_motivo, 'Pedido cancelado'), TRUE);
    UPDATE pedido SET status = 'CANCELADO' WHERE id_pedido = p_id_pedido;
    PERFORM set_config('app.motivo', '', TRUE);
END;
$$;

-- 3.6 Rotina agendada: cancela pedidos cujo prazo de pagamento venceu ------------------
-- Sugestão: executar a cada minuto (pg_cron, cron do sistema ou a aplicação Python):
--   CALL sp_expirar_reservas();
CREATE OR REPLACE PROCEDURE sp_expirar_reservas(INOUT p_qtd_expirados INTEGER DEFAULT 0)
LANGUAGE plpgsql AS $$
DECLARE
    v_id INTEGER;
BEGIN
    p_qtd_expirados := 0;
    FOR v_id IN SELECT id_pedido FROM pedido
                 WHERE tipo_pedido = 'ECOMMERCE' AND status = 'AGUARDANDO_PAGAMENTO'
                 ORDER BY id_pedido LOOP
        PERFORM 1 FROM pedido WHERE id_pedido = v_id FOR UPDATE;   -- trava e revalida
        IF fn_reserva_expirada(v_id) THEN
            CALL sp_cancelar_pedido(v_id, 'Reserva expirada por falta de pagamento');
            p_qtd_expirados := p_qtd_expirados + 1;
        END IF;
    END LOOP;
END;
$$;

-- 3.7 Encomenda aprovada -> pedido (sem reserva de estoque: será fabricada) --------------
-- Se a solicitação não tem produto do catálogo, cria um produto personalizado INATIVO.
CREATE OR REPLACE PROCEDURE sp_aprovar_encomenda(
    p_id_solicitacao INTEGER,
    p_preco_unitario NUMERIC,
    p_id_gerente     INTEGER,
    p_id_endereco    INTEGER DEFAULT NULL,
    p_id_categoria   INTEGER DEFAULT NULL,
    INOUT p_id_pedido INTEGER DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_sol  solicitacao_encomenda%ROWTYPE;
    v_end  endereco%ROWTYPE;
    v_nome VARCHAR(120);
BEGIN
    SELECT * INTO v_sol FROM solicitacao_encomenda WHERE id_solicitacao = p_id_solicitacao FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Solicitação % não encontrada.', p_id_solicitacao;
    END IF;
    IF v_sol.status <> 'EM_NEGOCIACAO' THEN
        RAISE EXCEPTION 'A solicitação % não está em negociação (status: %).', p_id_solicitacao, v_sol.status;
    END IF;

    IF p_id_endereco IS NOT NULL THEN
        SELECT * INTO v_end FROM endereco WHERE id_endereco = p_id_endereco AND id_usuario = v_sol.id_cliente;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'O endereço % não pertence ao cliente da solicitação.', p_id_endereco;
        END IF;
    END IF;
    SELECT nome INTO v_nome FROM usuario WHERE id_usuario = v_sol.id_cliente;

    IF v_sol.id_produto IS NULL THEN
        IF p_id_categoria IS NULL THEN
            RAISE EXCEPTION 'Informe p_id_categoria: a solicitação não tem produto do catálogo.';
        END IF;
        INSERT INTO produto (id_categoria, id_gerente, nome, descricao, preco, permite_personalizacao, ativo)
        VALUES (p_id_categoria, p_id_gerente, 'Personalizado - solicitação ' || p_id_solicitacao,
                v_sol.descricao_personalizacao, p_preco_unitario, TRUE, FALSE)
        RETURNING id_produto INTO v_sol.id_produto;
        UPDATE solicitacao_encomenda SET id_produto = v_sol.id_produto WHERE id_solicitacao = p_id_solicitacao;
    END IF;

    INSERT INTO pedido (id_cliente, id_endereco, id_solicitacao, tipo_pedido,
                        entrega_destinatario, entrega_cep, entrega_logradouro, entrega_numero,
                        entrega_complemento, entrega_bairro, entrega_cidade, entrega_estado, entrega_referencia)
    VALUES (v_sol.id_cliente, p_id_endereco, p_id_solicitacao, 'ENCOMENDA',
            CASE WHEN p_id_endereco IS NOT NULL THEN v_nome END,
            v_end.cep, v_end.logradouro, v_end.numero,
            v_end.complemento, v_end.bairro, v_end.cidade, v_end.estado, v_end.referencia)
    RETURNING id_pedido INTO p_id_pedido;

    INSERT INTO item_pedido (id_pedido, id_produto, quantidade, preco_unitario, observacao_personalizacao)
    VALUES (p_id_pedido, v_sol.id_produto, v_sol.quantidade, p_preco_unitario, v_sol.descricao_personalizacao);

    UPDATE pedido SET valor_total = fn_valor_total_pedido(p_id_pedido) WHERE id_pedido = p_id_pedido;
    UPDATE solicitacao_encomenda SET status = 'APROVADA' WHERE id_solicitacao = p_id_solicitacao;
END;
$$;

-- =============================================================================
-- 4) PRODUÇÃO x PEDIDO: valida status, produto e quantidade do pedido de origem
-- =============================================================================
CREATE OR REPLACE FUNCTION trg_producao_valida_pedido()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_status    VARCHAR(30);
    v_qtd_item  INTEGER;
    v_ja_produz INTEGER;
BEGIN
    IF NEW.tipo_producao <> 'PEDIDO' THEN
        RETURN NEW;
    END IF;

    SELECT status INTO v_status FROM pedido WHERE id_pedido = NEW.id_pedido FOR UPDATE;
    IF v_status NOT IN ('PAGO', 'EM_PRODUCAO') THEN
        RAISE EXCEPTION 'O pedido % não permite produção (status: %). É necessário estar pago.', NEW.id_pedido, v_status
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT COALESCE(SUM(quantidade), 0) INTO v_qtd_item
      FROM item_pedido WHERE id_pedido = NEW.id_pedido AND id_produto = NEW.id_produto;
    IF v_qtd_item = 0 THEN
        RAISE EXCEPTION 'O produto % não faz parte do pedido %.', NEW.id_produto, NEW.id_pedido
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT COALESCE(SUM(quantidade), 0) INTO v_ja_produz
      FROM producao
     WHERE id_pedido = NEW.id_pedido AND id_produto = NEW.id_produto AND status <> 'CANCELADA';
    IF v_ja_produz + NEW.quantidade > v_qtd_item THEN
        RAISE EXCEPTION 'Quantidade excede o pedido %: itens %, já em produção %, nova produção %.',
                        NEW.id_pedido, v_qtd_item, v_ja_produz, NEW.quantidade
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_producao_valida_pedido BEFORE INSERT ON producao
    FOR EACH ROW EXECUTE FUNCTION trg_producao_valida_pedido();