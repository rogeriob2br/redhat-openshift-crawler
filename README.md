# OpenShift Application Discovery & Assessment

Scripts para coleta de dados via API do OpenShift (`oc`) e geração de mapa/inventário de aplicações para apoiar a definição de divisão de clusters.

## Pré-requisitos
- `oc` CLI instalado e autenticado no cluster (`oc login ...`)
- **Linux/macOS:** `jq` instalado (e `xz` ou `gzip` para compactação)
- **Windows:** apenas PowerShell (nativo do Windows — não precisa de `jq` nem de `oc` no `PATH`)
- `python3` (apenas biblioteca padrão, sem dependências externas) para gerar os relatórios

## Como usar

### Coleta em Linux / macOS
1. Dê permissão de execução ao script:
   ```bash
   chmod +x 01-collect-cluster-raw.sh 02-generate-assessment-map.py
   ```
2. Execute a coleta conectado ao cluster:
   ```bash
   ./01-collect-cluster-raw.sh
   ```
   Isso criará o diretório `output/assessment-YYYYMMDD-HHMMSS/raw/` e o arquivo compactado `output/assessment-YYYYMMDD-HHMMSS.tar.xz` (ou `.tar.gz`/`.zip`).

### Coleta em Windows (PowerShell)
1. Execute o script apontando para o `oc.exe` (caso não esteja no `PATH`, o script também procura na pasta atual, `Downloads`, `C:\oc` ou pergunta interativamente):
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\01-collect-cluster-raw.ps1
   ```
   Ou informando o caminho diretamente:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\01-collect-cluster-raw.ps1 -OcPath "C:\caminho\para\oc.exe"
   ```
   Isso criará o arquivo compactado `output\assessment-YYYYMMDD-HHMMSS.zip`.

### Geração do mapa e relatórios (na sua máquina)
Após receber e descompactar o arquivo:
```bash
python3 02-generate-assessment-map.py output/assessment-YYYYMMDD-HHMMSS
```

## Segurança
- O script **não** salva o conteúdo (`.data`) de `Secrets` — apenas metadados e nomes das chaves.
- Senhas embutidas em URLs de variáveis de ambiente (`user:pass@host`) são mascaradas automaticamente no relatório de dependências.
