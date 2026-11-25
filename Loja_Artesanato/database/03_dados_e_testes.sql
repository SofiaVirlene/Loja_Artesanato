-- =============================================================================
-- LOJA VIRTUAL DE ARTESANATO - Banco de Dados II (IFPI - Campus Picos)
-- Arquivo 3 de 3: DADOS DE EXEMPLO + TESTES (CRUD e regras de negócio)
-- Execute depois de 01_estrutura.sql e 02_regras_negocio.sql
-- Cada teste imprime "OK - ..." (NOTICE); se algo falhar, o script para com erro.
-- =============================================================================
SET client_min_messages = notice;

-- =============================================================================
-- 1) DADOS DE EXEMPLO (INSERT)
-- =============================================================================
DO $$
DECLARE
    v_ger INTEGER; v_fab INTEGER; v_c1 INTEGER; v_c2 INTEGER; v_c3 INTEGER;
    v_cat1 INTEGER; v_cat2 INTEGER;
BEGIN
    -- usuários (perfil criado junto, na mesma transação)
    CALL sp_cadastrar_usuario('Maria Gerente',  'gerente@loja.com',   'senha12345', 'GERENTE',    p_nivel_acesso => 'ADMINISTRADOR', p_id_usuario => v_ger);
    CALL sp_cadastrar_usuario('Ana Artesã',     'fabricante@loja.com','senha12345', 'FABRICANTE', p_especialidade => 'Macramê',        p_id_usuario => v_fab);
    CALL sp_cadastrar_usuario('Cliente Um',     'cliente1@email.com', 'senha12345', 'CLIENTE', p_cpf => '52998224725', p_data_nascimento => '1998-05-10', p_id_usuario => v_c1);
    CALL sp_cadastrar_usuario('Cliente Dois',   'cliente2@email.com', 'senha12345', 'CLIENTE', p_cpf => '11144477735', p_id_usuario => v_c2);
    CALL sp_cadastrar_usuario('Cliente Três',   'cliente3@email.com', 'senha12345', 'CLIENTE', p_id_usuario => v_c3);  -- CPF só no checkout

    INSERT INTO endereco (id_usuario, cep, logradouro, numero, bairro, cidade, estado, referencia, endereco_principal)
    VALUES (v_c1, '64600000', 'Rua das Flores', '100', 'Centro', 'Picos', 'PI', 'Perto da praça', TRUE),
           (v_c2, '64600001', 'Av. Getúlio Vargas', '250', 'Junco', 'Picos', 'PI', NULL, TRUE),
           (v_c3, '64600002', 'Rua do Comércio', '15', 'Centro', 'Picos', 'PI', NULL, TRUE);
    INSERT INTO telefone (id_usuario, numero, tipo, principal) VALUES (v_c1, '89999990001', 'CELULAR', TRUE);

    INSERT INTO categoria (nome, descricao) VALUES ('Pulseiras', 'Pulseiras de macramê') RETURNING id_categoria INTO v_cat1;
    INSERT INTO categoria (nome, descricao) VALUES ('Chaveiros', 'Chaveiros artesanais') RETURNING id_categoria INTO v_cat2;

    INSERT INTO produto (id_categoria, id_gerente, nome, descricao, preco, permite_personalizacao) VALUES
        (v_cat1, v_ger, 'Pulseira Maré',  'Pulseira de macramê azul',   25.00, TRUE),
        (v_cat1, v_ger, 'Pulseira Sol',   'Pulseira de macramê amarela',30.00, TRUE),
        (v_cat2, v_ger, 'Chaveiro Boho',  'Chaveiro de macramê',        12.50, FALSE);

    INSERT INTO estoque_produto (id_produto, quantidade_disponivel)
    SELECT id_produto, 10 FROM produto;

    INSERT INTO material (nome, descricao, unidade_medida, custo_unitario) VALUES
        ('Fio de algodão encerado azul',  'Fio 1mm', 'METRO', 0.40),
        ('Fio de algodão encerado amarelo','Fio 1mm', 'METRO', 0.40),
        ('Fecho metálico', 'Fecho dourado', 'UNIDADE', 0.80);
    INSERT INTO estoque_material (id_material, quantidade_disponivel, estoque_minimo)
    SELECT id_material, 100, 10 FROM material;

    INSERT INTO fornecedor (nome, nome_empresa, cpf_cnpj, email) VALUES ('Casa dos Fios', 'Casa dos Fios LTDA', '12345678000195', 'contato@casadosfios.com');
    INSERT INTO fornecedor_material (id_fornecedor, id_material, preco_fornecimento)
    SELECT 1, id_material, custo_unitario FROM material;

    INSERT INTO produto_material (id_produto, id_material, quantidade_utilizada) VALUES
        (1, 1, 2.0), (1, 3, 1), (2, 2, 2.0), (2, 3, 1);

    INSERT INTO transportadora (nome, cnpj, telefone) VALUES ('Rápido Piauí', '98765432000110', '89988880000');
    INSERT INTO cartao (id_cliente, bandeira, ultimos_quatro_digitos, token_referencia, validade)
    VALUES (v_c1, 'VISA', '4242', 'tok_demo_c1', '2030-12-01');
    INSERT INTO carrinho (id_cliente) VALUES (v_c1), (v_c2), (v_c3);
    INSERT INTO item_carrinho (id_carrinho, id_produto, quantidade) VALUES (1, 1, 2), (1, 3, 1), (2, 2, 3), (3, 1, 1);
    RAISE NOTICE 'OK - dados de exemplo inseridos';
END $$;

-- =============================================================================
-- 2) TESTES DAS REGRAS DE NEGÓCIO
-- =============================================================================

-- T1: especialização total e disjunta de USUARIO
DO $$
BEGIN
    BEGIN
        INSERT INTO usuario (nome, email, senha_hash, tipo_usuario) VALUES ('Sem perfil', 'x@x.com', 'h', 'CLIENTE');
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'FALHOU: usuário sem perfil foi aceito';
    EXCEPTION WHEN integrity_constraint_violation THEN
        RAISE NOTICE 'OK - usuário sem registro de perfil é rejeitado';
    END;
    BEGIN   -- um mesmo usuário não pode ser CLIENTE e GERENTE (disjunção)
        INSERT INTO gerente (id_usuario, nivel_acesso) VALUES (3, 'BASICO');
        RAISE EXCEPTION 'FALHOU: usuário CLIENTE virou gerente';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'OK - usuário não pode ter dois perfis (disjunção)';
    END;
END $$;

-- T2: autenticação (hash) e CPF inválido
DO $$
BEGIN
    IF fn_autenticar_usuario('cliente1@email.com', 'senha12345') IS NULL THEN RAISE EXCEPTION 'FALHOU: login válido recusado'; END IF;
    IF fn_autenticar_usuario('cliente1@email.com', 'errada!!!') IS NOT NULL THEN RAISE EXCEPTION 'FALHOU: senha errada aceita'; END IF;
    RAISE NOTICE 'OK - autenticação por hash';
    BEGIN
        UPDATE cliente SET cpf = '11111111111' WHERE id_usuario = 4;
        RAISE EXCEPTION 'FALHOU: CPF inválido aceito';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK - CPF inválido é rejeitado';
    END;
END $$;

-- T3: finalizar pedido (reserva de estoque, valor, congelamento de endereço)
DO $$
DECLARE v_ped INTEGER; v_disp INTEGER; v_res INTEGER; v_tot NUMERIC;
BEGIN
    CALL sp_finalizar_pedido(1, 1, NULL, v_ped);   -- cliente 1: 2x Pulseira Maré + 1 Chaveiro
    SELECT valor_total INTO v_tot FROM pedido WHERE id_pedido = v_ped;
    IF v_tot <> 62.50 THEN RAISE EXCEPTION 'FALHOU: total esperado 62.50, obtido %', v_tot; END IF;
    SELECT quantidade_disponivel, quantidade_reservada INTO v_disp, v_res FROM estoque_produto WHERE id_produto = 1;
    IF v_disp <> 8 OR v_res <> 2 THEN RAISE EXCEPTION 'FALHOU: reserva incorreta (% / %)', v_disp, v_res; END IF;
    IF (SELECT status FROM carrinho WHERE id_carrinho = 1) <> 'CONVERTIDO' THEN RAISE EXCEPTION 'FALHOU: carrinho não convertido'; END IF;
    IF (SELECT entrega_logradouro FROM pedido WHERE id_pedido = v_ped) <> 'Rua das Flores' THEN RAISE EXCEPTION 'FALHOU: endereço não copiado'; END IF;
    IF (SELECT count(*) FROM historico_pedido WHERE id_pedido = v_ped) <> 1 THEN RAISE EXCEPTION 'FALHOU: histórico não gerado'; END IF;
    RAISE NOTICE 'OK - pedido % criado: total %, estoque reservado', v_ped, v_tot;
END $$;

-- T4: checkout exige CPF (cliente 3 sem CPF)
DO $$
DECLARE v_ped INTEGER;
BEGIN
    BEGIN
        CALL sp_finalizar_pedido(3, 3, NULL, v_ped);
        RAISE EXCEPTION 'FALHOU: checkout sem CPF aceito';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE '%CPF%' THEN RAISE; END IF;
        RAISE NOTICE 'OK - checkout sem CPF é recusado';
    END;
    CALL sp_finalizar_pedido(3, 3, '12345678909', v_ped);
    RAISE NOTICE 'OK - com CPF informado, o pedido % é criado', v_ped;
END $$;

-- T5: estoque insuficiente
DO $$
DECLARE v_ped INTEGER;
BEGIN
    -- carrinho 2 (Cliente Dois) ainda está aberto: pede 999 chaveiros
    INSERT INTO item_carrinho (id_carrinho, id_produto, quantidade) VALUES (2, 3, 999);
    BEGIN
        CALL sp_finalizar_pedido(2, 2, NULL, v_ped);
        RAISE EXCEPTION 'FALHOU: quantidade acima do estoque aceita';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK - estoque insuficiente é recusado (nada fica reservado)';
    END;
    DELETE FROM item_carrinho WHERE id_carrinho = 2 AND id_produto = 3;
END $$;

-- T6: pagamento (cartão de outro cliente, valor integral, aprovação, duplicidade)
DO $$
DECLARE v_pg INTEGER; v_pg2 INTEGER;
BEGIN
    BEGIN   -- cartão 1 pertence ao cliente 3 (id_usuario do cliente 1)? o pedido 2 é do cliente 5 -> deve falhar
        CALL sp_registrar_pagamento(2, 'CARTAO', 1, NULL, v_pg);
        RAISE EXCEPTION 'FALHOU: cartão de outro cliente aceito';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK - cartão de outro cliente é recusado';
    END;
    BEGIN
        CALL sp_registrar_pagamento(1, 'PIX', 1, NULL, v_pg);
        RAISE EXCEPTION 'FALHOU: Pix com cartão aceito';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK - Pix não pode informar cartão';
    END;

    CALL sp_registrar_pagamento(1, 'PIX', NULL, NULL, v_pg);
    CALL sp_registrar_pagamento(1, 'CARTAO', 1, NULL, v_pg2);
    CALL sp_recusar_pagamento(v_pg);                       -- primeira tentativa recusada
    CALL sp_aprovar_pagamento(v_pg2);                      -- segunda aprovada
    IF (SELECT status FROM pedido WHERE id_pedido = 1) <> 'PAGO' THEN RAISE EXCEPTION 'FALHOU: pedido não ficou PAGO'; END IF;
    IF (SELECT quantidade_reservada FROM estoque_produto WHERE id_produto = 1) <> 1 THEN RAISE EXCEPTION 'FALHOU: reserva do pedido 1 não consumida (resta só a do pedido 2)'; END IF;
    IF (SELECT quantidade_disponivel FROM estoque_produto WHERE id_produto = 1) <> 7 THEN RAISE EXCEPTION 'FALHOU: disponível alterado indevidamente'; END IF;
    RAISE NOTICE 'OK - várias tentativas de pagamento; uma aprovada consome a reserva e o pedido fica PAGO';

    BEGIN   -- não pode aprovar de novo
        CALL sp_aprovar_pagamento(v_pg2);
        RAISE EXCEPTION 'FALHOU: pagamento aprovado duas vezes';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'OK - pagamento já aprovado não é aprovado novamente';
    END;
    BEGIN   -- índice parcial: um APROVADO por pedido
        INSERT INTO pagamento (id_pedido, id_forma_pagamento, valor, status) VALUES (1, 1, 62.50, 'APROVADO');
        RAISE EXCEPTION 'FALHOU: segundo pagamento aprovado aceito';
    EXCEPTION WHEN unique_violation OR check_violation THEN
        RAISE NOTICE 'OK - apenas um pagamento aprovado por pedido';
    END;
END $$;

-- T7: transição de status inválida
DO $$
BEGIN
    BEGIN
        UPDATE pedido SET status = 'AGUARDANDO_PAGAMENTO' WHERE id_pedido = 1;
        RAISE EXCEPTION 'FALHOU: transição inválida aceita';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK - transição PAGO -> AGUARDANDO_PAGAMENTO é bloqueada';
    END;
END $$;

-- T8: cancelamento devolve a reserva ao estoque
DO $$
DECLARE v_disp_antes INTEGER; v_disp INTEGER;
BEGIN
    -- pedido 2 (cliente 3) reserva 1 Pulseira Maré
    SELECT quantidade_disponivel INTO v_disp_antes FROM estoque_produto WHERE id_produto = 1;
    CALL sp_cancelar_pedido(2, 'Cliente desistiu');
    SELECT quantidade_disponivel INTO v_disp FROM estoque_produto WHERE id_produto = 1;
    IF v_disp <> v_disp_antes + 1 THEN RAISE EXCEPTION 'FALHOU: reserva não devolvida'; END IF;
    IF (SELECT descricao FROM historico_pedido WHERE id_pedido = 2 AND status_novo = 'CANCELADO') <> 'Cliente desistiu' THEN
        RAISE EXCEPTION 'FALHOU: motivo não registrado no histórico';
    END IF;
    RAISE NOTICE 'OK - cancelamento devolve o estoque e registra o motivo no histórico';
    BEGIN
        CALL sp_cancelar_pedido(2);
        RAISE EXCEPTION 'FALHOU: cancelou duas vezes';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'OK - cancelar de novo não libera estoque em duplicidade';
    END;
END $$;

-- T9: expiração de reservas (30 min Pix/cartão; boleto até o vencimento)
DO $$
DECLARE v_c INTEGER; v_car INTEGER; v_p1 INTEGER; v_p2 INTEGER; v_p3 INTEGER; v_pg INTEGER; v_qtd INTEGER; v_disp0 INTEGER;
BEGIN
    SELECT quantidade_disponivel INTO v_disp0 FROM estoque_produto WHERE id_produto = 3;
    -- três pedidos do cliente 4 (Cliente Dois), um carrinho por vez
    FOR i IN 1..3 LOOP
        INSERT INTO carrinho (id_cliente) VALUES (4) ON CONFLICT DO NOTHING;
        SELECT id_carrinho INTO v_car FROM carrinho WHERE id_cliente = 4 AND status = 'ABERTO';
        DELETE FROM item_carrinho WHERE id_carrinho = v_car;
        INSERT INTO item_carrinho VALUES (v_car, 3, 1);
        IF i = 1 THEN CALL sp_finalizar_pedido(v_car, 2, NULL, v_p1);
        ELSIF i = 2 THEN CALL sp_finalizar_pedido(v_car, 2, NULL, v_p2);
        ELSE CALL sp_finalizar_pedido(v_car, 2, NULL, v_p3); END IF;
    END LOOP;
    -- p2 tem boleto vigente; p3 tem boleto vencido; p1 é Pix
    CALL sp_registrar_pagamento(v_p1, 'PIX', NULL, NULL, v_pg);
    CALL sp_registrar_pagamento(v_p2, 'BOLETO', NULL, CURRENT_DATE + 2, v_pg);
    CALL sp_registrar_pagamento(v_p3, 'BOLETO', NULL, CURRENT_DATE + 2, v_pg);
    UPDATE pagamento SET vencimento = CURRENT_DATE - 1 WHERE id_pedido = v_p3;
    -- envelhece todos em 1 hora
    UPDATE pedido SET data_pedido = now() - INTERVAL '1 hour' WHERE id_pedido IN (v_p1, v_p2, v_p3);

    CALL sp_expirar_reservas(v_qtd);
    IF v_qtd <> 2 THEN RAISE EXCEPTION 'FALHOU: esperado 2 pedidos expirados, obtido %', v_qtd; END IF;
    IF (SELECT status FROM pedido WHERE id_pedido = v_p1) <> 'CANCELADO' THEN RAISE EXCEPTION 'FALHOU: Pix vencido não cancelado'; END IF;
    IF (SELECT status FROM pedido WHERE id_pedido = v_p2) <> 'AGUARDANDO_PAGAMENTO' THEN RAISE EXCEPTION 'FALHOU: boleto vigente foi cancelado'; END IF;
    IF (SELECT status FROM pedido WHERE id_pedido = v_p3) <> 'CANCELADO' THEN RAISE EXCEPTION 'FALHOU: boleto vencido não cancelado'; END IF;
    IF (SELECT quantidade_disponivel FROM estoque_produto WHERE id_produto = 3) <> v_disp0 - 1 THEN
        RAISE EXCEPTION 'FALHOU: estoque após expiração incorreto';
    END IF;
    RAISE NOTICE 'OK - expiração: Pix/cartão após 30 min, boleto só após o vencimento; estoque devolvido';

    BEGIN   -- aprovar pagamento de pedido já expirado
        SELECT id_pagamento INTO v_pg FROM pagamento WHERE id_pedido = v_p1 LIMIT 1;
        CALL sp_aprovar_pagamento(v_pg);
        RAISE EXCEPTION 'FALHOU: aprovou pagamento de pedido expirado';
    EXCEPTION WHEN raise_exception OR check_violation THEN
        RAISE NOTICE 'OK - pagamento de pedido expirado não é aprovado';
    END;
    CALL sp_cancelar_pedido(v_p2, 'Limpeza do teste');
END $$;

-- T10: pedido de e-commerce pago -> entrega com envio e entrega
DO $$
DECLARE v_ent INTEGER;
BEGIN
    BEGIN   -- transportadora obrigatória na modalidade TRANSPORTADORA
        INSERT INTO entrega (id_pedido, modalidade) VALUES (1, 'TRANSPORTADORA');
        RAISE EXCEPTION 'FALHOU: modalidade TRANSPORTADORA sem transportadora';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK - modalidade TRANSPORTADORA exige transportadora';
    END;
    INSERT INTO entrega (id_pedido, modalidade, id_transportadora, codigo_rastreio, status)
    VALUES (1, 'TRANSPORTADORA', 1, 'BR123456789', 'PREPARANDO') RETURNING id_entrega INTO v_ent;
    UPDATE entrega SET status = 'ENVIADO', data_envio = now() WHERE id_entrega = v_ent;
    IF (SELECT status FROM pedido WHERE id_pedido = 1) <> 'ENVIADO' THEN RAISE EXCEPTION 'FALHOU: pedido não virou ENVIADO'; END IF;
    UPDATE entrega SET status = 'ENTREGUE', data_entrega = now() WHERE id_entrega = v_ent;
    IF (SELECT status FROM pedido WHERE id_pedido = 1) <> 'ENTREGUE' THEN RAISE EXCEPTION 'FALHOU: pedido não virou ENTREGUE'; END IF;
    IF (SELECT count(*) FROM historico_pedido WHERE id_pedido = 1) <> 5 THEN
        RAISE EXCEPTION 'FALHOU: histórico esperado com 5 registros, obtido %', (SELECT count(*) FROM historico_pedido WHERE id_pedido = 1);
    END IF;
    BEGIN   -- uma entrega por pedido
        INSERT INTO entrega (id_pedido, modalidade) VALUES (1, 'CORREIOS');
        RAISE EXCEPTION 'FALHOU: segunda entrega aceita';
    EXCEPTION WHEN unique_violation OR check_violation THEN
        RAISE NOTICE 'OK - apenas uma entrega por pedido';
    END;
    RAISE NOTICE 'OK - entrega atualiza o status do pedido; histórico completo (5 registros)';
END $$;

-- T11: encomenda personalizada -> pedido -> pagamento -> produção -> retirada
DO $$
DECLARE v_sol INTEGER; v_ped INTEGER; v_pg INTEGER; v_prod INTEGER; v_mat0 NUMERIC; v_mat NUMERIC;
BEGIN
    INSERT INTO solicitacao_encomenda (id_cliente, id_produto, quantidade, descricao_personalizacao, finalidade, data_evento)
    VALUES (4, 2, 5, 'Pulseiras com iniciais dos noivos', 'Lembrancinhas de casamento', CURRENT_DATE + 30)
    RETURNING id_solicitacao INTO v_sol;
    CALL sp_aprovar_encomenda(v_sol, 28.00, 1, NULL, NULL, v_ped);
    IF (SELECT valor_total FROM pedido WHERE id_pedido = v_ped) <> 140.00 THEN RAISE EXCEPTION 'FALHOU: total da encomenda'; END IF;
    IF (SELECT quantidade_reservada FROM estoque_produto WHERE id_produto = 2) <> 0 THEN RAISE EXCEPTION 'FALHOU: encomenda não deve reservar estoque'; END IF;

    CALL sp_registrar_pagamento(v_ped, 'PIX', NULL, NULL, v_pg);
    CALL sp_aprovar_pagamento(v_pg);
    IF (SELECT quantidade_reservada FROM estoque_produto WHERE id_produto = 2) <> 0 THEN RAISE EXCEPTION 'FALHOU: consumiu reserva inexistente'; END IF;

    BEGIN   -- produção de PEDIDO exige id_pedido
        INSERT INTO producao (id_produto, tipo_producao, id_fabricante, id_gerente, quantidade) VALUES (2, 'PEDIDO', 2, 1, 5);
        RAISE EXCEPTION 'FALHOU: produção de pedido sem pedido';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK - produção do tipo PEDIDO exige o pedido';
    END;

    INSERT INTO producao (id_pedido, id_produto, tipo_producao, id_fabricante, id_gerente, quantidade)
    VALUES (v_ped, 2, 'PEDIDO', 2, 1, 5) RETURNING id_producao INTO v_prod;
    IF (SELECT status FROM pedido WHERE id_pedido = v_ped) <> 'EM_PRODUCAO' THEN RAISE EXCEPTION 'FALHOU: pedido não ficou EM_PRODUCAO'; END IF;

    SELECT quantidade_disponivel INTO v_mat0 FROM estoque_material WHERE id_material = 2;
    UPDATE producao SET status = 'EM_ANDAMENTO' WHERE id_producao = v_prod;
    UPDATE producao SET status = 'CONCLUIDA'    WHERE id_producao = v_prod;
    SELECT quantidade_disponivel INTO v_mat FROM estoque_material WHERE id_material = 2;
    IF v_mat <> v_mat0 - 10 THEN RAISE EXCEPTION 'FALHOU: baixa de material (esperado %, obtido %)', v_mat0 - 10, v_mat; END IF;
    IF (SELECT status FROM pedido WHERE id_pedido = v_ped) <> 'PRONTO_ENVIO' THEN RAISE EXCEPTION 'FALHOU: pedido não ficou PRONTO_ENVIO'; END IF;
    IF (SELECT quantidade_disponivel FROM estoque_produto WHERE id_produto = 2) <> 10 THEN RAISE EXCEPTION 'FALHOU: produção de pedido não deve entrar no estoque'; END IF;

    INSERT INTO entrega (id_pedido, modalidade, status) VALUES (v_ped, 'RETIRADA', 'DISPONIVEL_RETIRADA');
    UPDATE entrega SET status = 'RETIRADO', data_entrega = now() WHERE id_pedido = v_ped;
    IF (SELECT status FROM pedido WHERE id_pedido = v_ped) <> 'ENTREGUE' THEN RAISE EXCEPTION 'FALHOU: retirada não concluiu o pedido'; END IF;
    RAISE NOTICE 'OK - encomenda: pedido sem reserva, produção baixa materiais, retirada conclui o pedido';
END $$;

-- T11b: produção só para pedido pago, com produto e quantidade do pedido
DO $$
BEGIN
    BEGIN   -- pedido 2 está CANCELADO
        INSERT INTO producao (id_pedido, id_produto, tipo_producao, id_fabricante, id_gerente, quantidade) VALUES (2, 1, 'PEDIDO', 2, 1, 1);
        RAISE EXCEPTION 'FALHOU: produção para pedido cancelado';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK - produção para pedido cancelado é recusada';
    END;
    BEGIN   -- pedido 6 (encomenda) só tem produto 2, e já foi entregue
        INSERT INTO producao (id_pedido, id_produto, tipo_producao, id_fabricante, id_gerente, quantidade) VALUES (6, 1, 'PEDIDO', 2, 1, 1);
        RAISE EXCEPTION 'FALHOU: produção fora do status permitido';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK - produção só é aceita para pedidos pagos / em produção';
    END;
END $$;

DO $$
DECLARE v_ped INTEGER; v_pg INTEGER; v_sol INTEGER;
BEGIN
    INSERT INTO solicitacao_encomenda (id_cliente, id_produto, quantidade, descricao_personalizacao)
    VALUES (4, 2, 2, 'Teste de validação') RETURNING id_solicitacao INTO v_sol;
    CALL sp_aprovar_encomenda(v_sol, 30.00, 1, NULL, NULL, v_ped);
    CALL sp_registrar_pagamento(v_ped, 'PIX', NULL, NULL, v_pg);
    CALL sp_aprovar_pagamento(v_pg);
    BEGIN   -- produto que não está no pedido
        INSERT INTO producao (id_pedido, id_produto, tipo_producao, id_fabricante, id_gerente, quantidade) VALUES (v_ped, 1, 'PEDIDO', 2, 1, 1);
        RAISE EXCEPTION 'FALHOU: produto fora do pedido aceito';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK - produto que não pertence ao pedido é recusado';
    END;
    BEGIN   -- quantidade maior que a do item (2)
        INSERT INTO producao (id_pedido, id_produto, tipo_producao, id_fabricante, id_gerente, quantidade) VALUES (v_ped, 2, 'PEDIDO', 2, 1, 3);
        RAISE EXCEPTION 'FALHOU: quantidade acima do pedido aceita';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'OK - quantidade acima da do pedido é recusada';
    END;
END $$;

-- T12: produção de REPOSIÇÃO aumenta o estoque disponível
DO $$
DECLARE v_prod INTEGER; v_antes INTEGER;
BEGIN
    SELECT quantidade_disponivel INTO v_antes FROM estoque_produto WHERE id_produto = 1;
    INSERT INTO producao (id_produto, tipo_producao, id_fabricante, id_gerente, quantidade)
    VALUES (1, 'REPOSICAO', 2, 1, 4) RETURNING id_producao INTO v_prod;
    UPDATE producao SET status = 'CONCLUIDA' WHERE id_producao = v_prod;
    IF (SELECT quantidade_disponivel FROM estoque_produto WHERE id_produto = 1) <> v_antes + 4 THEN
        RAISE EXCEPTION 'FALHOU: reposição não somou ao estoque';
    END IF;
    RAISE NOTICE 'OK - produção de reposição soma ao estoque disponível';
END $$;

-- T13: pedido sem itens é rejeitado no COMMIT
DO $$
BEGIN
    BEGIN
        INSERT INTO pedido (id_cliente, tipo_pedido) VALUES (4, 'ECOMMERCE');
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'FALHOU: pedido sem itens aceito';
    EXCEPTION WHEN integrity_constraint_violation THEN
        RAISE NOTICE 'OK - pedido sem itens é rejeitado';
    END;
END $$;

-- =============================================================================
-- 3) CONSULTAS DE CONFERÊNCIA (SELECT)
-- =============================================================================
--\echo '--- Pedidos e status ---'
SELECT p.id_pedido, u.nome AS cliente, p.tipo_pedido, p.status, p.valor_total
FROM pedido p JOIN usuario u ON u.id_usuario = p.id_cliente ORDER BY p.id_pedido;

--\echo '--- Estoque de produtos ---'
SELECT pr.nome, e.quantidade_disponivel AS disponivel, e.quantidade_reservada AS reservada
FROM estoque_produto e JOIN produto pr ON pr.id_produto = e.id_produto ORDER BY pr.id_produto;

--\echo '--- Histórico do pedido 1 ---'
SELECT status_anterior, status_novo, descricao FROM historico_pedido WHERE id_pedido = 1 ORDER BY id_historico;