# Desafio DevOps – Lacrei Saúde

API simples em Node.js com deploy automatizado para staging e produção na AWS, usando Docker e GitHub Actions.

## O projeto

```javascript
app.get('/status', (req, res) => {
    res.status(200).json({
        status: 'UP',
        timestamp: new Date().toISOString(),
        uptime: process.uptime(),
        message: 'Servidor rodando com sucesso na porta ' + PORT
    });
});
```

### Dockerfile

```dockerfile
FROM node:20-alpine
WORKDIR /api
COPY package*.json ./
RUN npm ci --only=production
COPY . .
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser
ENV NODE_ENV=production
EXPOSE 3000
CMD ["node", "index.js"]
```

Usei uma imagem Alpine e separei a instalação de dependências do resto do código pra aproveitar cache de build, e a aplicação roda com um usuário sem privilégios de root dentro do container.

## Ambientes

Staging e produção rodam em duas instâncias EC2 separadas (`lacrei-staging` e `lacrei-producao`), cada uma com Docker, Git, Nginx e Certbot instalados. Como não tenho um domínio próprio, usei subdomínios gratuitos do DuckDNS pra conseguir gerar certificado HTTPS de verdade:

- Staging: https://lacreii-staging.duckdns.org/status
- Produção: https://lacreii-prod.duckdns.org/status

O Nginx faz o papel de proxy reverso: recebe a conexão em HTTPS (443) e repassa internamente pro container, que roda na porta 3000. A porta 3000 não fica exposta pra internet, só o Nginx conversa com ela.

As credenciais de acesso ficam guardadas como GitHub Secrets, nunca no código.

## Pipeline

São três workflows no GitHub Actions:

**CI** roda em toda PR e em push pra `main` ou `develop`. Ele instala as dependências, roda lint (ESLint), builda a imagem Docker e sobe um container de teste pra confirmar que a rota `/status` responde antes de qualquer coisa seguir adiante.

**Deploy Staging** e **Deploy Produção** disparam automaticamente depois que o CI termina, e só rodam de verdade se o CI tiver passado, não bastam mais só o push na branch. Isso foi um ajuste que fiz depois de perceber no teste de rollback, que o deploy de staging rodava mesmo com o CI falhando (os dois workflows disparavam pelo mesmo push, mas de forma independente). Corrigi trocando o gatilho de `push` pra `workflow_run`, condicionado ao CI ter concluído com sucesso.

Ou seja: você desenvolve e testa em `develop`, e quando está tudo certo, faz merge pra `main` pra ir pro ar em produção. Nenhum deploy acontece sem passar primeiro pelo lint e pelos testes do CI.

## Segurança

Os pontos que apliquei:

- Credenciais sensiveis guardadas no GitHub Secrets
- HTTPS obrigatório nos dois ambientes, com certificado Let's Encrypt renovando automaticamente
- Container rodando com usuário não-root
- A instância usa uma IAM Role própria, só com a permissão necessária pra mandar logs pro CloudWatch (nada além disso)
- A porta da aplicação (3000) não é acessível de fora, só através do Nginx
- Deploy bloqueado automaticamente se o CI (lint + testes) não passar

Um ponto que vale explicar: o SSH das instâncias está liberado pra qualquer IP (`0.0.0.0/0`), e não só pro meu IP como eu queria originalmente. Isso porque o GitHub Actions roda os deploys a partir de servidores com IP variável, então restringir por IP fixo bloquearia o próprio pipeline. O ideal pra resolver isso de verdade seria usar AWS Systems Manager (SSM) no lugar de SSH exposto, mas deixei como melhoria futura.

## Logs e monitoramento

Os logs da aplicação dá pra ver direto com `docker logs lacrei-app` em cada instância. Além disso, configurei o CloudWatch Agent pra mandar os logs de acesso e erro do Nginx pra um log group centralizado (`lacrei-app-logs`), com streams separados pra staging e produção.

Também criei um alarme de CPU: se a instância de produção passar de 80% de uso por 5 minutos, chega um e-mail de aviso via SNS.

## Rollback

Se um deploy quebrar alguma coisa, dá pra reverter de duas formas.

A mais rápida é manual: como o deploy sempre gera uma imagem Docker nova mas não apaga a anterior, dá pra listar as imagens (`docker images`), parar o container com problema e subir de novo usando o ID da imagem anterior.

```bash
docker stop lacrei-app && docker rm lacrei-app
docker run -d --name lacrei-app -p 3000:3000 --restart unless-stopped <ID_DA_IMAGEM_ANTERIOR>
```

Isso resolve o problema na hora, mas é temporário — se não reverter o código também, o próximo deploy automático vai trazer o erro de volta. Por isso, o passo seguinte é reverter o commit no Git e dar push de novo:

```bash
git revert HEAD
git push origin <branch>
```

Testei esse fluxo de ponta a ponta em staging: subi de propósito uma alteração quebrando a rota `/status`, confirmei que o ambiente ficou fora do ar, fiz o rollback manual via Docker (voltou a responder), e depois apliquei o `git revert` pra corrigir o código na origem, deixando o pipeline automático assumir de novo daí em diante. Foi justamente esse teste que revelou o problema do deploy não depender do CI, corrigido na seção de Pipeline.

## Erros que apareceram no caminho

Ao longo do desenvolvimento apareceram vários erros, que foram bem úteis pra entender melhor cada peça do processo:

O primeiro deploy falhou porque o secret com o IP da instância estava errado. Resolvido corrigindo o valor.

Depois, o SSH deu timeout pois o Security Group só liberava acesso pro meu IP, e o runner do GitHub Actions usa outro. Precisei abrir o SSH pra qualquer IP pra o pipeline funcionar (como expliquei na parte de segurança).

Em seguida, o deploy falhou porque o Git não vinha instalado por padrão na instância EC2. Precisei instalar manualmente e ajustar o script pra clonar o repositório automaticamente caso ele ainda não existisse na máquina.

Também tive um erro de autenticação SSH porque colei a chave errada (ou incompleta) no secret do GitHub algumas vezes, bastou recriar o secret com o conteúdo certo do arquivo `.pem`.

Na parte de HTTPS, o Certbot recusava gerar certificado porque eu estava tentando usar direto o IP da instância — Let's Encrypt não emite certificado pra IP, só pra domínio. Resolvi criando subdomínios gratuitos no DuckDNS.

Já configurando o CloudWatch, o agente ficava tentando enviar os logs sem sucesso por um tempo, era só a IAM Role recém-associada ainda não ter propagado direito. Reiniciando o agente depois de alguns minutos resolveu.

Testando o rollback de propósito, percebi que o deploy de staging ia pro ar mesmo com o CI falhando, porque os dois workflows disparavam pelo mesmo push mas de forma independente. Corrigi mudando o gatilho do deploy pra só rodar depois do CI terminar com sucesso (`workflow_run`).

## O que ficou de fora (e daria pra melhorar)

- Restringir o SSH por IP fixo, usando AWS SSM no lugar de acesso direto
- Guardar segredos da aplicação (não só de infraestrutura) no AWS Secrets Manager
- Versionar as imagens Docker com tags específicas em vez de sempre sobrescrever a mesma tag — isso tornaria o rollback mais preciso
- Um domínio próprio no lugar do DuckDNS

## Bônus: integração com Asaas (proposta)

Não cheguei a implementar, mas a ideia seria usar o split de pagamento nativo da Asaas: ao criar uma cobrança pela API, já se define o percentual que fica com a plataforma e o que é repassado automaticamente ao profissional de saúde. A confirmação do pagamento chegaria via webhook (evento `PAYMENT_CONFIRMED`), evitando ficar consultando a API o tempo todo. A chave de API da Asaas ficaria no AWS Secrets Manager, e usaria o ambiente sandbox deles em staging antes de qualquer coisa ir pra produção.

## Bônus: alertas

Esse eu implementei de verdade, não só documentei: o alarme de CPU do CloudWatch manda notificação por e-mail via SNS sempre que a produção passa de 80% de uso. Dá pra estender esse mesmo tópico SNS pra mandar aviso num canal do Slack também, se precisar.

## Links

- Repositório: https://github.com/PedroDelmiro13/devops-challenge
- Staging: https://lacreii-staging.duckdns.org/status
- Produção: https://lacreii-prod.duckdns.org/status
