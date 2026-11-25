# -*- coding: utf-8 -*-
"""
Loja virtual de artesanato - Aplicação em Python (terminal)
Banco de Dados II - IFPI Campus Picos

Requisitos:  pip install psycopg2-binary
Banco:       executar antes 01_estrutura.sql, 02_regras_negocio.sql e 03_dados_e_testes.sql
Execução:    python app_loja.py

Logins de exemplo (criados pelo 03_dados_e_testes.sql; senha: senha12345):
    gerente@loja.com    (gerente)
    cliente1@email.com  (cliente)
    fabricante@loja.com (fabricante)

Toda a regra de negócio (estoque, expiração, status...) está no banco (functions,
procedures e triggers). O Python só chama essas rotinas e controla a transação:
commit() quando dá certo e rollback() quando o banco recusa a operação.
"""
import os
import psycopg2
from dotenv import load_dotenv
from getpass import getpass

load_dotenv()

# ----------------------------------------------------------------------------
# Conexão e utilitários
# ----------------------------------------------------------------------------

def conectar():
    try:
        return psycopg2.connect(
            host=os.getenv("DB_HOST"),
            port=os.getenv("DB_PORT", "5432"),
            dbname=os.getenv("DB_NAME"),
            user=os.getenv("DB_USER"),
            password=os.getenv("DB_PASSWORD")
        )
    except psycopg2.Error as e:
        print("Não foi possível conectar ao banco:", e)
        return None

def executar(conn, acao):
    """Roda a ação numa transação: commit se der certo, rollback se o banco recusar."""
    try:
        with conn.cursor() as cur:
            resultado = acao(cur)
        conn.commit()
        return resultado
    except psycopg2.Error as e:
        conn.rollback()
        print("\n  [Operação recusada pelo banco] " + (e.diag.message_primary or str(e)))
        return None


def consultar(conn, sql, params=()):
    try:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            linhas = cur.fetchall()
        conn.commit()
        return linhas
    except psycopg2.Error as e:
        conn.rollback()
        print("\n  [Erro] " + (e.diag.message_primary or str(e)))
        return []


def tabela(cabecalho, linhas):
    if not linhas:
        print("  (nenhum registro)")
        return
    dados = [[("" if c is None else str(c)) for c in l] for l in linhas]
    larg = [max(len(h), *(len(l[i]) for l in dados)) for i, h in enumerate(cabecalho)]
    print("  " + " | ".join(h.ljust(larg[i]) for i, h in enumerate(cabecalho)))
    print("  " + "-+-".join("-" * w for w in larg))
    for l in dados:
        print("  " + " | ".join(c.ljust(larg[i]) for i, c in enumerate(l)))


def ler_texto(msg, obrigatorio=True):
    while True:
        v = input(msg).strip()
        if v or not obrigatorio:
            return v or None
        print("  Campo obrigatório.")


def ler_int(msg, opcional=False):
    while True:
        v = input(msg).strip()
        if not v and opcional:
            return None
        try:
            return int(v)
        except ValueError:
            print("  Digite um número inteiro.")


def ler_num(msg):
    while True:
        try:
            return float(input(msg).strip().replace(",", "."))
        except ValueError:
            print("  Digite um valor numérico.")


def titulo(texto):
    print("\n" + "=" * 60 + "\n  " + texto + "\n" + "=" * 60)


# ----------------------------------------------------------------------------
# Cadastro e login
# ----------------------------------------------------------------------------
def cadastrar_cliente(conn):
    titulo("CADASTRO DE CLIENTE")
    nome = ler_texto("Nome: ")
    email = ler_texto("E-mail: ")
    senha = getpass("Senha (mín. 8 caracteres): ")
    cpf = ler_texto("CPF (somente números; Enter para informar depois): ", False)
    r = executar(conn, lambda c: (
        c.execute("CALL sp_cadastrar_usuario(%s, %s, %s, 'CLIENTE', %s, NULL, 'BASICO', NULL, NULL)",
                  (nome, email, senha, cpf)),
        c.fetchone())[1])
    if r:
        print(f"\n  Cadastro realizado! Seu código de usuário é {r[0]}.")

def entrar(conn):
    titulo("ENTRAR")
    email = ler_texto("E-mail: ")
    senha = getpass("Senha: ")
    r = consultar(conn, "SELECT fn_autenticar_usuario(%s, %s)", (email, senha))
    if not r or r[0][0] is None:
        print("\n  E-mail ou senha incorretos.")
        return None, None
    uid = r[0][0]
    tipo = consultar(conn, "SELECT nome, tipo_usuario FROM usuario WHERE id_usuario = %s", (uid,))[0]
    print(f"\n  Bem-vinda(o), {tipo[0]}!")
    return uid, tipo[1]


# ----------------------------------------------------------------------------
# Área do CLIENTE
# ----------------------------------------------------------------------------
def listar_catalogo(conn):
    titulo("CATÁLOGO")
    linhas = consultar(conn, """
        SELECT p.id_produto, p.nome, c.nome, p.preco, e.quantidade_disponivel
          FROM produto p
          JOIN categoria c ON c.id_categoria = p.id_categoria
          LEFT JOIN estoque_produto e ON e.id_produto = p.id_produto
         WHERE p.ativo ORDER BY p.id_produto""")
    tabela(["Cód", "Produto", "Categoria", "Preço", "Disponível"], linhas)


def carrinho_aberto(conn, uid):
    def acao(c):
        c.execute("SELECT id_carrinho FROM carrinho WHERE id_cliente = %s AND status = 'ABERTO'", (uid,))
        r = c.fetchone()
        if r:
            return r[0]
        c.execute("INSERT INTO carrinho (id_cliente) VALUES (%s) RETURNING id_carrinho", (uid,))
        return c.fetchone()[0]
    return executar(conn, acao)


def adicionar_ao_carrinho(conn, uid):
    listar_catalogo(conn)
    idp = ler_int("\nCódigo do produto: ")
    qtd = ler_int("Quantidade: ")
    car = carrinho_aberto(conn, uid)
    if car is None:
        return
    ok = executar(conn, lambda c: c.execute("""
        INSERT INTO item_carrinho (id_carrinho, id_produto, quantidade) VALUES (%s, %s, %s)
        ON CONFLICT (id_carrinho, id_produto)
        DO UPDATE SET quantidade = item_carrinho.quantidade + EXCLUDED.quantidade""", (car, idp, qtd)) or True)
    if ok:
        print("  Produto adicionado ao carrinho.")


def ver_carrinho(conn, uid):
    titulo("MEU CARRINHO")
    linhas = consultar(conn, """
        SELECT p.id_produto, p.nome, ic.quantidade, p.preco, ic.quantidade * p.preco
          FROM carrinho c
          JOIN item_carrinho ic ON ic.id_carrinho = c.id_carrinho
          JOIN produto p ON p.id_produto = ic.id_produto
         WHERE c.id_cliente = %s AND c.status = 'ABERTO' ORDER BY p.id_produto""", (uid,))
    tabela(["Cód", "Produto", "Qtd", "Preço", "Subtotal"], linhas)
    if linhas:
        print(f"\n  TOTAL: R$ {sum(l[4] for l in linhas):.2f}")
    return linhas


def remover_do_carrinho(conn, uid):
    if not ver_carrinho(conn, uid):
        return
    idp = ler_int("\nCódigo do produto a remover: ")
    executar(conn, lambda c: c.execute("""
        DELETE FROM item_carrinho WHERE id_produto = %s AND id_carrinho =
          (SELECT id_carrinho FROM carrinho WHERE id_cliente = %s AND status = 'ABERTO')""", (idp, uid)))
    print("  Item removido (se existia).")


def cadastrar_endereco(conn, uid):
    titulo("NOVO ENDEREÇO")
    cep = ler_texto("CEP (8 dígitos): ")
    logr = ler_texto("Logradouro: ")
    num = ler_texto("Número: ")
    comp = ler_texto("Complemento (Enter para pular): ", False)
    bairro = ler_texto("Bairro: ")
    cidade = ler_texto("Cidade: ")
    uf = ler_texto("UF: ").upper()
    ref = ler_texto("Ponto de referência (Enter para pular): ", False)
    r = executar(conn, lambda c: (c.execute("""
        INSERT INTO endereco (id_usuario, cep, logradouro, numero, complemento, bairro, cidade, estado, referencia)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s) RETURNING id_endereco""",
        (uid, cep, logr, num, comp, bairro, cidade, uf, ref)), c.fetchone())[1])
    if r:
        print(f"  Endereço {r[0]} cadastrado.")

def cadastrar_cartao(conn, uid):
    titulo("NOVO CARTÃO (simulação)")
    print("  Bandeiras: VISA, MASTERCARD, ELO, AMEX, HIPERCARD")
    band = ler_texto("Bandeira: ").upper()
    ult = ler_texto("Últimos 4 dígitos: ")
    val = ler_texto("Validade (AAAA-MM-DD): ")
    r = executar(conn, lambda c: (c.execute("""
        INSERT INTO cartao (id_cliente, bandeira, ultimos_quatro_digitos, validade)
        VALUES (%s, %s, %s, %s) RETURNING id_cartao""", (uid, band, ult, val)), c.fetchone())[1])
    if r:
        print(f"  Cartão {r[0]} cadastrado (nunca guardamos o número completo).")


def finalizar_pedido(conn, uid):
    if not ver_carrinho(conn, uid):
        return
    car = carrinho_aberto(conn, uid)
    ends = consultar(conn, "SELECT id_endereco, logradouro, numero, bairro, cidade FROM endereco WHERE id_usuario = %s", (uid,))
    print("\n  Seus endereços:")
    tabela(["Cód", "Logradouro", "Nº", "Bairro", "Cidade"], ends)
    ide = ler_int("\nCódigo do endereço de entrega (Enter = retirada na loja): ", opcional=True)
    tem_cpf = consultar(conn, "SELECT cpf FROM cliente WHERE id_usuario = %s", (uid,))[0][0]
    cpf = None if tem_cpf else ler_texto("CPF (obrigatório para finalizar a compra): ")
    r = executar(conn, lambda c: (
        c.execute("CALL sp_finalizar_pedido(%s, %s, %s, NULL)", (car, ide, cpf)), c.fetchone())[1])
    if r:
        tot = consultar(conn, "SELECT valor_total FROM pedido WHERE id_pedido = %s", (r[0],))[0][0]
        print(f"\n  Pedido {r[0]} criado! Total: R$ {tot}. Estoque reservado por 30 min (Pix/cartão).")


def meus_pedidos(conn, uid):
    titulo("MEUS PEDIDOS")
    linhas = consultar(conn, """
        SELECT id_pedido, to_char(data_pedido, 'DD/MM/YYYY HH24:MI'), tipo_pedido, status, valor_total
          FROM pedido WHERE id_cliente = %s ORDER BY id_pedido""", (uid,))
    tabela(["Pedido", "Data", "Tipo", "Status", "Total"], linhas)
    return linhas


def historico(conn, uid):
    if not meus_pedidos(conn, uid):
        return
    idp = ler_int("\nCódigo do pedido: ")
    linhas = consultar(conn, """
        SELECT to_char(h.data_alteracao, 'DD/MM HH24:MI:SS'), h.status_anterior, h.status_novo, h.descricao
          FROM historico_pedido h JOIN pedido p ON p.id_pedido = h.id_pedido
         WHERE h.id_pedido = %s AND p.id_cliente = %s ORDER BY h.id_historico""", (idp, uid))
    tabela(["Quando", "De", "Para", "Descrição"], linhas)


def pagar_pedido(conn, uid):
    pend = consultar(conn, """SELECT id_pedido, valor_total FROM pedido
                               WHERE id_cliente = %s AND status = 'AGUARDANDO_PAGAMENTO' ORDER BY id_pedido""", (uid,))
    titulo("PAGAR PEDIDO")
    tabela(["Pedido", "Total"], pend)
    if not pend:
        return
    idp = ler_int("\nCódigo do pedido: ")
    if idp not in [p[0] for p in pend]:
        print("  Esse pedido não está na sua lista de pedidos aguardando pagamento.")
        return
    print("  1) Pix   2) Cartão   3) Boleto")
    op = ler_int("Forma de pagamento: ")
    forma = {1: "PIX", 2: "CARTAO", 3: "BOLETO"}.get(op)
    if not forma:
        print("  Opção inválida.")
        return
    idc, venc = None, None
    if forma == "CARTAO":
        cartoes = consultar(conn, "SELECT id_cartao, bandeira, ultimos_quatro_digitos FROM cartao WHERE id_cliente = %s", (uid,))
        tabela(["Cód", "Bandeira", "Final"], cartoes)
        idc = ler_int("Código do cartão: ")
        if idc not in [c[0] for c in cartoes]:
            print("  Esse cartão não pertence a você.")
            return
    if forma == "BOLETO":
        venc = ler_texto("Vencimento (AAAA-MM-DD; Enter = 3 dias): ", False)
    r = executar(conn, lambda c: (
        c.execute("CALL sp_registrar_pagamento(%s, %s, %s, %s::date, NULL)", (idp, forma, idc, venc)),
        c.fetchone())[1])
    if not r:
        return
    print(f"\n  Pagamento {r[0]} registrado, aguardando confirmação.")
    if input("  Simular aprovação do gateway agora? (s/n): ").strip().lower() == "s":
        if executar(conn, lambda c: c.execute("CALL sp_aprovar_pagamento(%s)", (r[0],)) or True):
            print("  Pagamento aprovado! Pedido PAGO.")


def cancelar_pedido(conn, uid):
    pend = consultar(conn, """SELECT id_pedido, valor_total FROM pedido
                               WHERE id_cliente = %s AND status = 'AGUARDANDO_PAGAMENTO' ORDER BY id_pedido""", (uid,))
    titulo("CANCELAR PEDIDO")
    tabela(["Pedido", "Total"], pend)
    if not pend:
        return
    idp = ler_int("\nCódigo do pedido: ")
    if idp not in [p[0] for p in pend]:
        print("  Esse pedido não está na sua lista de pedidos aguardando pagamento.")
        return
    if executar(conn, lambda c: c.execute("CALL sp_cancelar_pedido(%s, 'Cancelado pelo cliente')", (idp,)) or True):
        print("  Pedido cancelado e estoque devolvido.")


def menu_cliente(conn, uid):
    ops = {
        "1": ("Ver catálogo", lambda: listar_catalogo(conn)),
        "2": ("Adicionar ao carrinho", lambda: adicionar_ao_carrinho(conn, uid)),
        "3": ("Ver carrinho", lambda: ver_carrinho(conn, uid)),
        "4": ("Remover item do carrinho", lambda: remover_do_carrinho(conn, uid)),
        "5": ("Cadastrar endereço", lambda: cadastrar_endereco(conn, uid)),
        "6": ("Cadastrar cartão", lambda: cadastrar_cartao(conn, uid)),
        "7": ("Finalizar pedido", lambda: finalizar_pedido(conn, uid)),
        "8": ("Pagar pedido", lambda: pagar_pedido(conn, uid)),
        "9": ("Meus pedidos", lambda: meus_pedidos(conn, uid)),
        "10": ("Histórico de um pedido", lambda: historico(conn, uid)),
        "11": ("Cancelar pedido", lambda: cancelar_pedido(conn, uid)),
        "12": ("Solicitar encomenda personalizada", lambda: solicitar_encomenda(conn, uid)),
        "13": ("Minhas solicitações de encomenda", lambda: minhas_solicitacoes(conn, uid)),
    }
    while True:
        titulo("ÁREA DO CLIENTE")
        for k, (nome, _) in ops.items():
            print(f"  {k.rjust(2)}) {nome}")
        print("   0) Sair da conta")
        op = input("\nEscolha: ").strip()
        if op == "0":
            return
        if op in ops:
            ops[op][1]()
        else:
            print("  Opção inválida.")


# ----------------------------------------------------------------------------
# Área do GERENTE (CRUD de produtos, pagamentos, entregas, expiração)
# ----------------------------------------------------------------------------
def listar_produtos_gerente(conn):
    titulo("PRODUTOS (todos)")
    linhas = consultar(conn, """
        SELECT p.id_produto, p.nome, c.nome, p.preco, p.ativo,
               COALESCE(e.quantidade_disponivel, 0), COALESCE(e.quantidade_reservada, 0)
          FROM produto p JOIN categoria c ON c.id_categoria = p.id_categoria
          LEFT JOIN estoque_produto e ON e.id_produto = p.id_produto ORDER BY p.id_produto""")
    tabela(["Cód", "Produto", "Categoria", "Preço", "Ativo", "Disp.", "Reserv."], linhas)


def criar_produto(conn, uid):
    titulo("NOVO PRODUTO (CREATE)")
    tabela(["Cód", "Categoria"], consultar(conn, "SELECT id_categoria, nome FROM categoria WHERE status ORDER BY 1"))
    cat = ler_int("Código da categoria: ")
    nome = ler_texto("Nome: ")
    desc = ler_texto("Descrição (Enter para pular): ", False)
    preco = ler_num("Preço: ")
    qtd = ler_int("Quantidade inicial em estoque: ")
    enc = input("Aceita encomenda sob demanda? (S/n, Enter = sim): ").strip().lower() != "n"
    pers = input("Aceita personalização? (s/N, Enter = não): ").strip().lower() == "s"

    def acao(c):
        c.execute("""INSERT INTO produto (id_categoria, id_gerente, nome, descricao, preco, permite_encomenda, permite_personalizacao)
        VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING id_produto""", (cat, uid, nome, desc, preco, enc, pers))
        idp = c.fetchone()[0]
        c.execute("INSERT INTO estoque_produto (id_produto, quantidade_disponivel) VALUES (%s, %s)", (idp, qtd))
        return idp
    r = executar(conn, acao)
    if r:
        print(f"  Produto {r} criado.")


def atualizar_produto(conn):
    listar_produtos_gerente(conn)
    idp = ler_int("\nCódigo do produto: ")
    print("  1) Alterar preço   2) Alterar nome   3) Ativar/Desativar   4) Ajustar estoque disponível")
    op = ler_int("Opção: ")
    if op == 1:
        sql, par = "UPDATE produto SET preco = %s WHERE id_produto = %s", (ler_num("Novo preço: "), idp)
    elif op == 2:
        sql, par = "UPDATE produto SET nome = %s WHERE id_produto = %s", (ler_texto("Novo nome: "), idp)
    elif op == 3:
        sql, par = "UPDATE produto SET ativo = NOT ativo WHERE id_produto = %s", (idp,)
    elif op == 4:
        sql, par = ("UPDATE estoque_produto SET quantidade_disponivel = %s WHERE id_produto = %s",
                    (ler_int("Nova quantidade disponível: "), idp))
    else:
        print("  Opção inválida.")
        return
    if executar(conn, lambda c: c.execute(sql, par) or True):
        print("  Atualizado.")


def excluir_produto(conn):
    listar_produtos_gerente(conn)
    idp = ler_int("\nCódigo do produto a excluir: ")
    if input("  Confirma a exclusão? (s/n): ").strip().lower() != "s":
        return

    def acao(c):
        c.execute("DELETE FROM estoque_produto WHERE id_produto = %s", (idp,))
        c.execute("DELETE FROM produto WHERE id_produto = %s", (idp,))
    if executar(conn, lambda c: acao(c) or True):
        print("  Produto excluído (se já foi vendido, o banco recusa: use 'Ativar/Desativar').")


def todos_pedidos(conn):
    titulo("TODOS OS PEDIDOS")
    linhas = consultar(conn, """
        SELECT p.id_pedido, u.nome, p.tipo_pedido, p.status, p.valor_total
          FROM pedido p JOIN usuario u ON u.id_usuario = p.id_cliente ORDER BY p.id_pedido""")
    tabela(["Pedido", "Cliente", "Tipo", "Status", "Total"], linhas)


def pagamentos_pendentes(conn):
    titulo("PAGAMENTOS PENDENTES (simulação do gateway)")
    linhas = consultar(conn, """
        SELECT pg.id_pagamento, pg.id_pedido, f.descricao, pg.valor, pg.vencimento
          FROM pagamento pg JOIN forma_pagamento f ON f.id_forma_pagamento = pg.id_forma_pagamento
         WHERE pg.status = 'PENDENTE' ORDER BY pg.id_pagamento""")
    tabela(["Pagamento", "Pedido", "Forma", "Valor", "Vencimento"], linhas)
    if not linhas:
        return
    idpg = ler_int("\nCódigo do pagamento (Enter para voltar): ", opcional=True)
    if idpg is None:
        return
    a = input("  1) Aprovar   2) Recusar: ").strip()
    proc = {"1": "sp_aprovar_pagamento", "2": "sp_recusar_pagamento"}.get(a)
    if proc and executar(conn, lambda c: c.execute(f"CALL {proc}(%s)", (idpg,)) or True):
        print("  Feito.")


def registrar_entrega(conn):
    titulo("ENTREGA")
    linhas = consultar(conn, """
        SELECT p.id_pedido, p.status, e.modalidade, e.status
          FROM pedido p LEFT JOIN entrega e ON e.id_pedido = p.id_pedido
         WHERE p.status IN ('PAGO', 'PRONTO_ENVIO', 'ENVIADO') ORDER BY p.id_pedido""")
    tabela(["Pedido", "Status pedido", "Modalidade", "Status entrega"], linhas)
    if not linhas:
        return
    idp = ler_int("\nCódigo do pedido: ")
    atual = consultar(conn, "SELECT modalidade FROM entrega WHERE id_pedido = %s", (idp,))
    if not atual:
        print("  1) CORREIOS   2) TRANSPORTADORA   3) ENTREGA_PROPRIA   4) RETIRADA")
        mod = {1: "CORREIOS", 2: "TRANSPORTADORA", 3: "ENTREGA_PROPRIA", 4: "RETIRADA"}.get(ler_int("Modalidade: "))
        if not mod:
            print("  Opção inválida.")
            return
        idt = None
        if mod == "TRANSPORTADORA":
            transp = consultar(conn, "SELECT id_transportadora, nome FROM transportadora ORDER BY 1")
            tabela(["Cód", "Transportadora"], transp)
            idt = ler_int("Código da transportadora: ")
            if idt not in [t[0] for t in transp]:
                print("  Transportadora inválida.")
                return
        rastreio = ler_texto("Código de rastreio (Enter para pular): ", False) if mod in ("CORREIOS", "TRANSPORTADORA") else None
        st = "DISPONIVEL_RETIRADA" if mod == "RETIRADA" else "PREPARANDO"
        if executar(conn, lambda c: c.execute(
                "INSERT INTO entrega (id_pedido, modalidade, id_transportadora, codigo_rastreio, status) VALUES (%s, %s, %s, %s, %s)",
                (idp, mod, idt, rastreio, st)) or True):
            print(f"  Entrega registrada ({st}).")
        return
    mod = atual[0][0]
    opcoes = ["RETIRADO"] if mod == "RETIRADA" else ["ENVIADO", "ENTREGUE"]
    print("  Novo status: " + " / ".join(f"{i + 1}) {o}" for i, o in enumerate(opcoes)))
    i = ler_int("Opção: ")
    if not 1 <= i <= len(opcoes):
        print("  Opção inválida.")
        return
    if executar(conn, lambda c: c.execute(
            "UPDATE entrega SET status = %s WHERE id_pedido = %s", (opcoes[i - 1], idp)) or True):
        print("  Entrega atualizada; o status do pedido acompanha automaticamente (trigger).")


def expirar_reservas(conn):
    r = executar(conn, lambda c: (c.execute("CALL sp_expirar_reservas(0)"), c.fetchone())[1])
    if r:
        print(f"\n  {r[0]} pedido(s) expirado(s) e estoque devolvido.")


def menu_gerente(conn, uid):
    ops = {
        "1": ("Listar produtos (READ)", lambda: listar_produtos_gerente(conn)),
        "2": ("Cadastrar produto (CREATE)", lambda: criar_produto(conn, uid)),
        "3": ("Atualizar produto (UPDATE)", lambda: atualizar_produto(conn)),
        "4": ("Excluir produto (DELETE)", lambda: excluir_produto(conn)),
        "5": ("Ver todos os pedidos", lambda: todos_pedidos(conn)),
        "6": ("Pagamentos pendentes (aprovar/recusar)", lambda: pagamentos_pendentes(conn)),
        "7": ("Registrar/atualizar entrega", lambda: registrar_entrega(conn)),
        "8": ("Expirar reservas vencidas", lambda: expirar_reservas(conn)),
        "9": ("Encomendas personalizadas (aprovar/recusar)", lambda: gerenciar_encomendas(conn, uid)),
        "10": ("Produção e fabricantes", lambda: producao_gerente(conn, uid)),
    }
    while True:
        titulo("ÁREA DO GERENTE")
        for k, (nome, _) in ops.items():
            print(f"  {k.rjust(2)}) {nome}")
        print("   0) Sair da conta")
        op = input("\nEscolha: ").strip()
        if op == "0":
            return
        if op in ops:
            ops[op][1]()
        else:
            print("  Opção inválida.")


# ----------------------------------------------------------------------------
# Encomendas personalizadas (cliente e gerente)
# ----------------------------------------------------------------------------
def solicitar_encomenda(conn, uid):
    titulo("SOLICITAR ENCOMENDA PERSONALIZADA")
    prods = consultar(conn, "SELECT id_produto, nome, preco FROM produto WHERE ativo AND permite_personalizacao ORDER BY 1")
    print("  Produtos que aceitam personalização:")
    tabela(["Cód", "Produto", "Preço base"], prods)
    idp = ler_int("\nCódigo do produto-base (Enter = modelo totalmente novo): ", opcional=True)
    if idp is not None and idp not in [p[0] for p in prods]:
        print("  Produto inválido.")
        return
    qtd = ler_int("Quantidade: ")
    desc = ler_texto("Descreva a personalização (cores, nomes, tamanho...): ")
    fin = ler_texto("Finalidade (ex.: casamento; Enter para pular): ", False)
    data = ler_texto("Data do evento (AAAA-MM-DD; Enter para pular): ", False)
    r = executar(conn, lambda c: (c.execute("""
        INSERT INTO solicitacao_encomenda (id_cliente, id_produto, quantidade, descricao_personalizacao, finalidade, data_evento)
        VALUES (%s, %s, %s, %s, %s, %s::date) RETURNING id_solicitacao""",
        (uid, idp, qtd, desc, fin, data)), c.fetchone())[1])
    if r:
        print(f"  Solicitação {r[0]} enviada! A loja vai analisar e combinar o preço com você.")


def minhas_solicitacoes(conn, uid):
    titulo("MINHAS SOLICITAÇÕES DE ENCOMENDA")
    linhas = consultar(conn, """
        SELECT s.id_solicitacao, COALESCE(p.nome, '(modelo novo)'), s.quantidade, s.status,
               (SELECT id_pedido FROM pedido WHERE id_solicitacao = s.id_solicitacao)
          FROM solicitacao_encomenda s LEFT JOIN produto p ON p.id_produto = s.id_produto
         WHERE s.id_cliente = %s ORDER BY s.id_solicitacao""", (uid,))
    tabela(["Cód", "Produto", "Qtd", "Status", "Pedido gerado"], linhas)
    if any(l[4] for l in linhas):
        print("\n  Pedidos de encomenda aprovados aparecem em 'Pagar pedido'.")


def gerenciar_encomendas(conn, uid):
    titulo("ENCOMENDAS EM NEGOCIAÇÃO")
    linhas = consultar(conn, """
        SELECT s.id_solicitacao, u.nome, COALESCE(p.nome, '(modelo novo)'), s.quantidade, s.descricao_personalizacao
          FROM solicitacao_encomenda s
          JOIN usuario u ON u.id_usuario = s.id_cliente
          LEFT JOIN produto p ON p.id_produto = s.id_produto
         WHERE s.status = 'EM_NEGOCIACAO' ORDER BY s.id_solicitacao""")
    tabela(["Cód", "Cliente", "Produto", "Qtd", "Personalização"], linhas)
    if not linhas:
        return
    ids = ler_int("\nCódigo da solicitação (Enter para voltar): ", opcional=True)
    if ids is None:
        return
    if ids not in [l[0] for l in linhas]:
        print("  Solicitação inválida.")
        return
    op = input("  1) Aprovar e gerar pedido   2) Recusar: ").strip()
    if op == "2":
        if executar(conn, lambda c: c.execute(
                "UPDATE solicitacao_encomenda SET status = 'RECUSADA' WHERE id_solicitacao = %s", (ids,)) or True):
            print("  Solicitação recusada.")
        return
    if op != "1":
        print("  Opção inválida.")
        return
    preco = ler_num("Preço unitário combinado: R$ ")
    info = consultar(conn, "SELECT id_cliente, id_produto FROM solicitacao_encomenda WHERE id_solicitacao = %s", (ids,))[0]
    ends = consultar(conn, "SELECT id_endereco, logradouro, numero, bairro FROM endereco WHERE id_usuario = %s", (info[0],))
    tabela(["Cód", "Logradouro", "Nº", "Bairro"], ends)
    ide = ler_int("Código do endereço de entrega (Enter = retirada): ", opcional=True)
    cat = None
    if info[1] is None:
        tabela(["Cód", "Categoria"], consultar(conn, "SELECT id_categoria, nome FROM categoria WHERE status ORDER BY 1"))
        cat = ler_int("Categoria do novo modelo: ")
    r = executar(conn, lambda c: (c.execute(
        "CALL sp_aprovar_encomenda(%s, %s, %s, %s::integer, %s::integer, NULL)",
        (ids, preco, uid, ide, cat)), c.fetchone())[1])
    if r:
        print(f"\n  Pedido {r[0]} criado. O cliente deve pagar; depois a produção pode ser atribuída.")


# ----------------------------------------------------------------------------
# Produção (gerente atribui; fabricante executa)
# ----------------------------------------------------------------------------
def listar_producoes(conn, filtro_fab=None):
    sql = """SELECT pr.id_producao, pr.tipo_producao, pr.id_pedido, p.nome, pr.quantidade, u.nome, pr.status
               FROM producao pr JOIN produto p ON p.id_produto = pr.id_produto
               JOIN usuario u ON u.id_usuario = pr.id_fabricante"""
    par = ()
    if filtro_fab:
        sql += " WHERE pr.id_fabricante = %s"
        par = (filtro_fab,)
    linhas = consultar(conn, sql + " ORDER BY pr.id_producao", par)
    tabela(["Prod.", "Tipo", "Pedido", "Produto", "Qtd", "Fabricante", "Status"], linhas)
    return linhas

def escolher_fabricante(conn):
    fabs = consultar(conn, "SELECT f.id_usuario, u.nome FROM fabricante f JOIN usuario u ON u.id_usuario = f.id_usuario WHERE u.status ORDER BY 1")
    tabela(["Cód", "Fabricante"], fabs)
    idf = ler_int("Código do fabricante: ")
    return idf if idf in [f[0] for f in fabs] else None


def producao_gerente(conn, uid):
    while True:
        titulo("PRODUÇÃO")
        print("  1) Listar produções\n  2) Criar produção de um pedido\n  3) Criar produção de reposição de estoque\n  4) Cancelar produção\n  0) Voltar")
        op = input("\nEscolha: ").strip()
        if op == "0":
            return
        if op == "1":
            listar_producoes(conn)
        elif op == "2":
            itens = consultar(conn, """
                SELECT * FROM (
                  SELECT p.id_pedido, ip.id_produto, pr.nome, ip.quantidade,
                         ip.quantidade - COALESCE((SELECT SUM(x.quantidade) FROM producao x
                              WHERE x.id_pedido = ip.id_pedido AND x.id_produto = ip.id_produto AND x.status <> 'CANCELADA'), 0) AS falta
                    FROM pedido p JOIN item_pedido ip ON ip.id_pedido = p.id_pedido
                    JOIN produto pr ON pr.id_produto = ip.id_produto
                   WHERE p.status IN ('PAGO', 'EM_PRODUCAO')) t
                WHERE falta > 0 ORDER BY 1, 2""")
            tabela(["Pedido", "Produto", "Nome", "Qtd pedida", "Falta produzir"], itens)
            if not itens:
                continue
            idped = ler_int("\nCódigo do pedido: ")
            idprod = ler_int("Código do produto: ")
            if (idped, idprod) not in [(i[0], i[1]) for i in itens]:
                print("  Pedido/produto inválido ou já totalmente em produção.")
                continue
            falta = [i[4] for i in itens if (i[0], i[1]) == (idped, idprod)][0]
            qtd = ler_int(f"Quantidade a produzir (máx. {falta}): ")
            if not 1 <= qtd <= falta:
                print(f"  Quantidade inválida: faltam produzir {falta} unidade(s) deste item.")
                continue
            idf = escolher_fabricante(conn)
            if idf is None:
                print("  Fabricante inválido.")
                continue
            if executar(conn, lambda c: c.execute("""
                    INSERT INTO producao (id_pedido, id_produto, tipo_producao, id_fabricante, id_gerente, quantidade)
                    VALUES (%s, %s, 'PEDIDO', %s, %s, %s)""", (idped, idprod, idf, uid, qtd)) or True):
                print("  Produção criada; o pedido passa a EM_PRODUCAO.")
        elif op == "3":
            listar_produtos_gerente(conn)
            idprod = ler_int("\nCódigo do produto a repor: ")
            qtd = ler_int("Quantidade: ")
            idf = escolher_fabricante(conn)
            if idf is None:
                print("  Fabricante inválido.")
                continue
            if executar(conn, lambda c: c.execute("""
                    INSERT INTO producao (id_produto, tipo_producao, id_fabricante, id_gerente, quantidade)
                    VALUES (%s, 'REPOSICAO', %s, %s, %s)""", (idprod, idf, uid, qtd)) or True):
                print("  Produção de reposição criada.")
        elif op == "4":
            if not listar_producoes(conn):
                continue
            idpr = ler_int("\nCódigo da produção a cancelar: ")
            n = executar(conn, lambda c: (c.execute(
                "UPDATE producao SET status = 'CANCELADA' WHERE id_producao = %s AND status IN ('AGUARDANDO', 'EM_ANDAMENTO')",
                (idpr,)), c.rowcount)[1])
            print("  Produção cancelada." if n else "  Não foi possível cancelar (inexistente ou já concluída).")
        else:
            print("  Opção inválida.")


def mudar_status_producao(conn, uid, de, para, texto):
    if not listar_producoes(conn, uid):
        return
    idpr = ler_int("\nCódigo da produção: ")
    mats = consultar(conn, """
        SELECT m.nome, pm.quantidade_utilizada * pr.quantidade, em.quantidade_disponivel, m.unidade_medida
          FROM producao pr JOIN produto_material pm ON pm.id_produto = pr.id_produto
          JOIN material m ON m.id_material = pm.id_material
          JOIN estoque_material em ON em.id_material = m.id_material
         WHERE pr.id_producao = %s AND pr.id_fabricante = %s""", (idpr, uid))
    if mats:
        print("  Materiais necessários x disponíveis:")
        tabela(["Material", "Necessário", "Disponível", "Unidade"], mats)
    n = executar(conn, lambda c: (c.execute(
        "UPDATE producao SET status = %s WHERE id_producao = %s AND id_fabricante = %s AND status = %s",
        (para, idpr, uid, de)), c.rowcount)[1])
    if n:
        print(f"  Produção {texto}.")
    elif n == 0:
        print(f"  Não foi possível: a produção precisa ser sua e estar com status {de}.")


def menu_fabricante(conn, uid):
    while True:
        titulo("ÁREA DO FABRICANTE")
        print("  1) Minhas produções\n  2) Iniciar produção\n  3) Concluir produção\n  0) Sair da conta")
        op = input("\nEscolha: ").strip()
        if op == "0":
            return
        if op == "1":
            titulo("MINHAS PRODUÇÕES")
            listar_producoes(conn, uid)
        elif op == "2":
            mudar_status_producao(conn, uid, "AGUARDANDO", "EM_ANDAMENTO", "iniciada")
        elif op == "3":
            mudar_status_producao(conn, uid, "EM_ANDAMENTO", "CONCLUIDA", "concluída (materiais baixados do estoque)")
        else:
            print("  Opção inválida.")


# ----------------------------------------------------------------------------
# Programa principal
# ----------------------------------------------------------------------------

def main():
    conn = conectar()

    if conn is None:
        return

    while True:
        titulo("LOJA VIRTUAL DE ARTESANATO")
        print("  1) Entrar\n  2) Cadastrar-me como cliente\n  0) Encerrar")
        op = input("\nEscolha: ").strip()

        if op == "1":
            uid, tipo = entrar(conn)
            if tipo == "CLIENTE":
                menu_cliente(conn, uid)
            elif tipo == "GERENTE":
                menu_gerente(conn, uid)
            elif tipo == "FABRICANTE":
                menu_fabricante(conn, uid)

        elif op == "2":
            cadastrar_cliente(conn)

        elif op == "0":
            break

        else:
            print("  Opção inválida.")

    conn.close()
    print("Até logo!")


if __name__ == "__main__":
    main()
