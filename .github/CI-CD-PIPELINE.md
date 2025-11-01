# CI/CD Pipeline - ZeroTier Sidecar

## Общая схема

```
┌──────────────────────────────────────────────────────────────────────┐
│ 1. ПУБЛИЧНЫЙ РЕПОЗИТОРИЙ: alexbic/zerotier-sidecar                  │
│    Push to main/gateway branch                                       │
└──────────────────────────────────────────────────────────────────────┘
                             ↓
                    (repository_dispatch)
                             ↓
┌──────────────────────────────────────────────────────────────────────┐
│ 2. ТЕСТОВЫЙ РЕПОЗИТОРИЙ: alexbic/zerotier-sidecar-test              │
│    📋 Test Workflow (test.yml)                                       │
│                                                                       │
│    - Checkout code from public repo                                  │
│    - Build Docker image                                              │
│    - Deploy to test environment:                                     │
│      * NAS Web Service (10.121.15.16)                               │
│      * NAS API Service (10.121.15.16)                               │
│      * VPS Gateway (10.121.15.15)                                   │
│    - Run E2E tests (all 3 modes)                                     │
│    - Test network isolation                                          │
│                                                                       │
│    ✅ Tests PASSED                                                   │
└──────────────────────────────────────────────────────────────────────┘
                             ↓
                    (repository_dispatch)
                             ↓
┌──────────────────────────────────────────────────────────────────────┐
│ 3. DEPLOY WORKFLOW (deploy.yml)                                      │
│                                                                       │
│    - Checkout code                                                   │
│    - Build multi-platform Docker image                              │
│    - Push to Docker Hub                                              │
│    - Create GitHub Release                                           │
│    - Create Git Tag                                                  │
│                                                                       │
│    🚀 DEPLOYED                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

## Workflows

### 1. CI Workflow (public repo) - `ci.yml`

**Триггеры:**
- `push` to main/gateway
- `pull_request` to main/gateway

**Задачи:**
1. Quick local checks (syntax, file structure)
2. Trigger tests in private test repository via `repository_dispatch`

**Защита:**
- Не запускается для PR из форков (нет доступа к secrets)
- Только syntax checks для PR

### 2. Test Workflow (private repo) - `test.yml`

**Триггеры:**
- `repository_dispatch` (event: test-and-deploy) - автоматически из публичного репо
- `workflow_dispatch` - ручной запуск для отладки

**Задачи:**
1. **nas-web** - Deploy NAS Web Service + sidecar (Backend mode)
2. **nas-api** - Deploy NAS API Service + sidecar (Backend mode)
3. **vps-gateway** - Deploy VPS Gateway (Gateway mode)
4. **test-e2e-connectivity** - 5 сценариев E2E тестов
5. **test-network-isolation** - Проверка изоляции сетей
6. **trigger-deploy** - Если все тесты ✅ → автоматически запускает deploy

**Параметры:**
- `test_type`: full, vps-gateway, nas-web, nas-api, connectivity
- `cleanup_mode`: auto, manual
- `source_branch`: main, gateway

**Окружения:**
- NAS test runner: `10.121.15.16`
- VPS test runner: `10.121.15.15`
- ZeroTier network: `10.121.15.x`

### 3. Deploy Workflow (private repo) - `deploy.yml`

**Триггеры:**
- `repository_dispatch` (event: auto-deploy) - автоматически после успешных тестов
- `workflow_dispatch` - ручной запуск

**Задачи:**
1. Checkout code from public repo
2. Version bump (patch/minor/custom)
3. Build multi-platform Docker image (linux/amd64, linux/arm64)
4. Push to Docker Hub: `alexbic/zerotier-sidecar:gateway`, `alexbic/zerotier-sidecar:vX.X.X`
5. Create GitHub Release with changelog
6. Create and push Git tag

**Параметры:**
- `source_branch`: main, gateway
- `version_type`: patch, minor, custom
- `custom_version`: vX.X.X (опционально)
- `release_notes`: Custom notes (опционально)

## Автоматический vs Ручной запуск

### Автоматический Pipeline (Push to main/gateway)

```bash
# Developer pushes to main/gateway
git push origin gateway

# 1. ci.yml запускается автоматически
#    ↓ repository_dispatch
# 2. test.yml запускается автоматически
#    - Проходят все E2E тесты
#    ↓ repository_dispatch (если тесты ✅)
# 3. deploy.yml запускается автоматически
#    - Build & Push to Docker Hub
#    - Create Release
```

### Ручное тестирование (без deploy)

```bash
# Запустить только тесты
gh workflow run test.yml \
  --repo alexbic/zerotier-sidecar-test \
  -f test_type=full \
  -f source_branch=gateway \
  -f cleanup_mode=manual
```

### Ручной deploy (без тестов)

```bash
# Например, rebuild существующей версии
gh workflow run deploy.yml \
  --repo alexbic/zerotier-sidecar-test \
  -f source_branch=gateway \
  -f version_type=patch
```

## Secrets Required

### Public Repository (`alexbic/zerotier-sidecar`)

- `TEST_REPO_PAT` - Personal Access Token для trigger workflow в test repo
  - Scopes: `repo`, `workflow`

### Private Repository (`alexbic/zerotier-sidecar-test`)

- `ZEROTIER_SIDECAR_PAT` - PAT для работы с main репозиторием
  - Scopes: `repo`, `workflow` (write:packages пока не используется, GHCR отключен)
- `DOCKERHUB_USERNAME` - Docker Hub username
- `DOCKERHUB_TOKEN` - Docker Hub access token

## Runner Labels

### Test Runners (в zerotier-sidecar-test)

- NAS Web: `[self-hosted, Linux, NAS, test, zerotier, internal, nas-web]`
- NAS API: `[self-hosted, Linux, NAS, test, zerotier, internal, nas-api]`
- VPS Gateway: `[self-hosted, Linux, VPS, test]`

### Deploy Runner (в zerotier-sidecar-test)

- `[self-hosted, Linux, VPS, test]`

## Безопасность

### Public Repository Protection

1. **Fork PR Protection**
   - Settings → Actions → Fork pull request workflows
   - ✅ Require approval for first-time contributors
   - ✅ Require approval for all outside collaborators

2. **Actions Permissions**
   - Settings → Actions → Actions permissions
   - ✅ Allow local actions only

3. **Self-hosted Runner**
   - Специфичные labels - форки не могут использовать
   - Secrets недоступны в PR из форков

### Private Repository Protection

1. **Protected Environment** (для deploy)
   - Environment: `production`
   - Required reviewers: owner
   - Deployment branches: main, gateway

2. **Runner Isolation**
   - Test runners изолированы от production
   - Cleanup после каждого теста

## Мониторинг

### View Workflow Runs

```bash
# Public repo CI
gh run list --repo alexbic/zerotier-sidecar

# Test runs
gh run list --repo alexbic/zerotier-sidecar-test --workflow=test.yml

# Deploy runs
gh run list --repo alexbic/zerotier-sidecar-test --workflow=deploy.yml
```

### Watch Logs

```bash
# Latest test run
gh run watch --repo alexbic/zerotier-sidecar-test $(gh run list --repo alexbic/zerotier-sidecar-test --workflow=test.yml --limit 1 --json databaseId --jq '.[0].databaseId')
```

## Troubleshooting

### Тесты не запускаются автоматически

1. Проверьте `TEST_REPO_PAT` secret в публичном репо:
   ```bash
   gh secret list --repo alexbic/zerotier-sidecar
   ```

2. Проверьте что PAT имеет scope `workflow`

### Deploy не запускается после тестов

1. Проверьте условие в test.yml → trigger-deploy job:
   - `AUTO_DEPLOY` должен быть `true`
   - `github.event_name` должен быть `repository_dispatch`

2. Проверьте логи test workflow:
   ```bash
   gh run view <run-id> --repo alexbic/zerotier-sidecar-test --log
   ```

### Тесты падают с ошибкой DNS resolution

См. [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) в основном репозитории.

## Future Improvements

- [ ] Добавить Slack/Discord уведомления о статусе deploy
- [ ] Добавить rollback mechanism
- [ ] Добавить canary deployment
- [ ] Интеграция с GitHub Container Registry (GHCR)
- [ ] Performance benchmarks в тестах
- [ ] Security scanning (Trivy, Snyk)
