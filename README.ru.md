# 🌐 ZeroTier Sidecar Gateway v2.0

[![Docker Pulls](https://img.shields.io/docker/pulls/alexbic/zerotier-sidecar)](https://hub.docker.com/r/alexbic/zerotier-sidecar)
[![Docker Image Size](https://img.shields.io/docker/image-size/alexbic/zerotier-sidecar/latest)](https://hub.docker.com/r/alexbic/zerotier-sidecar)
[![License](https://img.shields.io/github/license/alexbic/zerotier-sidecar)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/alexbic/zerotier-sidecar)](https://github.com/alexbic/zerotier-sidecar/stargazers)

[🇺🇸 English](README.md) | 🇷🇺 Русский

Мощный Docker контейнер, который действует как мост ZeroTier сети с несколькими режимами работы:
- **Режим Backend**: ZeroTier сети → Docker контейнеры  
- **Режим Gateway**: Интернет → ZeroTier сети (НОВОЕ!)
- **Гибридный режим**: Оба направления одновременно

Идеально подходит для создания безопасных цепочек доступа и удаленного доступа к сервисам через зашифрованную сеть ZeroTier.

## 🐳 Docker Hub

**Готовый образ Docker**: [`alexbic/zerotier-sidecar`](https://hub.docker.com/r/alexbic/zerotier-sidecar)

```bash
# Стабильная версия (v1.x - только режим Backend)
docker pull alexbic/zerotier-sidecar:latest

# Версия с Gateway режимом (v2.x - все режимы)
docker pull alexbic/zerotier-sidecar:gateway
```

## 🚀 Возможности

### Основные функции
- **🔐 Безопасная переадресация портов**: Гибкое маппирование портов с автоматическим определением протокола
- **📦 Простое развертывание**: Один Docker контейнер с простой конфигурацией
- **🌐 Полная интеграция с ZeroTier**: Бесшовный мост между сетями
- **🛡️ Автоматическая безопасность**: Встроенные правила firewall с защитой от сканирования портов

### Режимы работы (НОВОЕ в v2.0)
- **Режим Backend**: Традиционная переадресация ZeroTier → Docker
- **Режим Gateway**: Туннелирование Интернет → ZeroTier с автоматическим прокси
- **Гибридный режим**: Одновременная двунаправленная переадресация

### Расширенные функции (НОВОЕ в v2.0)
- **🔍 Умная маршрутизация**: Автоматическое определение ZeroTier vs Docker сетей
- **🎯 Пользовательские маршруты**: Поддержка сложных сетевых топологий
- **🔒 Фильтрация источников**: Контроль доступа на основе IP
- **📊 Мониторинг в реальном времени**: Подробное логирование и отслеживание конфигурации

## 🎯 Сценарии использования

### Режим Backend (Традиционный)
- **🏠 Доступ к домашней лаборатории**: Безопасный доступ к домашним сервисам откуда угодно
- **💾 Удаленное резервное копирование**: Включение rsync, NAS или служб резервного копирования через ZeroTier
- **🖥️ Разработка**: Удаленный доступ к средам разработки

### Режим Gateway (НОВОЕ!)
- **🌉 Безопасные туннели**: Создание цепочек доступа Интернет→ZeroTier→Сервисы
- **🔒 Jump серверы**: Безопасные точки входа в частные сети  
- **🏢 Корпоративный доступ**: Контролируемый внешний доступ к внутренним сервисам
- **🌍 Глобальное распределение**: Доступ к сервисам в разных географических регионах

### Продвинутые сценарии
- **📡 IoT подключение**: Подключение IoT устройств через сложные сетевые топологии
- **🔧 Системное администрирование**: Многошаговый SSH и управление сервисами
- **🔄 Балансировка нагрузки**: Распределение трафика по ZeroTier сетям

## 📋 Архитектура

### Режим Backend (Традиционный)
```
ZeroTier клиент → ZeroTier сеть → Sidecar (iptables) → Docker сервис
                                  (172.26.0.2)        (172.26.0.3:873)
```

### Режим Gateway (НОВОЕ!)
```
Интернет клиент → Gateway Sidecar (socat) → ZeroTier → Backend Sidecar (iptables) → Docker сервис
                (203.0.113.100)  (172.26.0.2:8989)            (10.121.15.16:8989)    (172.20.0.2:8080)
```

### Гибридный режим
```
Интернет клиент ──┐
                  ├→ Гибридный Sidecar ←─ ZeroTier клиент
ZeroTier клиент ──┘     (все режимы)
                            ↓
                     Docker сервисы
```

## 📋 Быстрый старт

### Режим Backend (Традиционный)

1. **Создайте директорию проекта**:
```bash
mkdir zerotier-backend && cd zerotier-backend
```

2. **Создайте `docker-compose.yml`**:
```yaml
version: "3.8"

services:
  zerotier-sidecar:
    image: alexbic/zerotier-sidecar:latest
    container_name: zerotier-sidecar
    restart: unless-stopped
    privileged: true
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ./sidecar-data:/var/lib/zerotier-one
    networks:
      - default
    env_file:
      - stack.env
    dns:
      - 8.8.8.8
      - 1.1.1.1
    cap_add:
      - NET_ADMIN
      - SYS_ADMIN

networks:
  default:
    name: sidecar_net
```

3. **Создайте `stack.env`**:
```bash
# Режим backend (по умолчанию)
ZT_NETWORK=ваш_id_zerotier_сети_здесь
PORT_FORWARD=873:172.26.0.3:873,22:172.26.0.4:22
GATEWAY_MODE=false
```

### Режим Gateway (НОВОЕ!)

1. **Gateway сервер - `docker-compose.yml`**:
```yaml
version: "3.8"

services:
  zerotier-gateway:
    image: alexbic/zerotier-sidecar:gateway
    container_name: zerotier-gateway
    restart: unless-stopped
    privileged: true
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - "8989:8989"  # Открыт для Интернета
      - "443:443"    # HTTPS доступ
    volumes:
      - ./gateway-data:/var/lib/zerotier-one
    env_file:
      - stack.env
    cap_add:
      - NET_ADMIN
      - SYS_ADMIN
```

2. **Gateway сервер - `stack.env`**:
```bash
# Режим gateway - принимает трафик из Интернета и переадресует в ZeroTier
ZT_NETWORK=ваш_id_zerotier_сети_здесь
PORT_FORWARD=8989:10.121.15.16:8989,443:10.121.15.20:443
GATEWAY_MODE=true
ALLOWED_SOURCES=203.0.113.0/24  # Ваши разрешенные исходные сети
```

3. **Backend сервер - `stack.env`**:
```bash
# Режим backend - получает из ZeroTier и переадресует в Docker
ZT_NETWORK=ваш_id_zerotier_сети_здесь
PORT_FORWARD=8989:172.20.0.2:8080,443:172.20.0.3:443
GATEWAY_MODE=false
```

## ⚙️ Конфигурация

### Переменные окружения

| Переменная | Обязательная | Описание | По умолчанию | Пример |
|------------|--------------|-----------|--------------|---------|
| `ZT_NETWORK` | ✅ | ID ZeroTier сети | - | `a03edd986708c010` |
| `PORT_FORWARD` | ✅ | Правила переадресации портов | - | `8989:10.121.15.16:8989` |
| `GATEWAY_MODE` | ❌ | Режим работы | `false` | `false`, `true`, `hybrid` |
| `ALLOWED_SOURCES` | ❌ | Разрешенные IP источники | `any` | `203.0.113.0/24,10.0.0.0/8` |
| `FORCE_ZEROTIER_ROUTES` | ❌ | Пользовательские ZeroTier маршруты | - | `192.168.1.0/24:10.121.15.50` |

### Режимы работы

- **`GATEWAY_MODE=false`** (Backend): ZeroTier → Docker (традиционный режим)
- **`GATEWAY_MODE=true`** (Gateway): Интернет → ZeroTier (новый режим)  
- **`GATEWAY_MODE=hybrid`** (Гибридный): Оба направления одновременно

### Формат переадресации портов

**Базовый формат**: `ВНЕШНИЙ_ПОРТ:IP_НАЗНАЧЕНИЯ:ПОРТ_НАЗНАЧЕНИЯ`

**Примеры режима Backend**:
- Один сервис: `873:172.26.0.3:873`
- Несколько сервисов: `873:172.26.0.3:873,22:172.26.0.4:22,80:172.26.0.5:8080`

**Примеры режима Gateway**:
- Переадресация в ZeroTier: `8989:10.121.15.16:8989`
- Несколько шлюзов: `8989:10.121.15.16:8989,443:10.121.15.20:443`

### Расширенная маршрутизация (НОВОЕ!)

Для сложных сетевых топологий, где назначения маршрутизируются через ZeroTier:

```bash
# Маршрутизация частных сетей через определенные ZeroTier шлюзы
FORCE_ZEROTIER_ROUTES=192.168.1.0/24:10.121.15.50,10.0.0.0/16:10.121.15.100

# Пример: Доступ к корпоративной сети через ZeroTier
PORT_FORWARD=3389:192.168.10.100:3389,22:192.168.20.50:22
FORCE_ZEROTIER_ROUTES=192.168.10.0/24:10.121.15.10,192.168.20.0/24:10.121.15.20
```

## 🔐 Соображения безопасности

### Сетевая безопасность
- **Изоляция**: Используйте выделенные Docker сети для разных уровней сервисов
- **Авторизация**: Всегда авторизуйте устройства в ZeroTier Central
- **Firewall**: Автоматические правила iptables с защитой от сканирования портов
- **Контроль источников**: Используйте `ALLOWED_SOURCES` для ограничения доступа

### Лучшие практики безопасности в продакшене

**ВАЖНО**: В продакшн среде никогда не выставляйте порты sidecar напрямую в интернет. Всегда используйте обратный прокси.

#### Рекомендуемая архитектура:
```
Интернет → Обратный прокси (80/443) → Внутренняя сеть → ZeroTier Sidecar → Сервисы
          (nginx/traefik)               (Docker сеть)
```

#### Пример безопасного развертывания:
```yaml
# docker-compose.yml - ПРОДАКШН УСТАНОВКА
version: "3.8"

services:
  # Обратный прокси - ЕДИНСТВЕННЫЙ сервис, открытый в интернет
  nginx-proxy:
    image: nginx:alpine
    ports:
      - "80:80"
      - "443:443"    # ТОЛЬКО эти порты открыты в интернет
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf
    networks:
      - frontend
      - backend

  # ZeroTier Gateway - БЕЗ внешних портов
  zerotier-gateway:
    image: alexbic/zerotier-sidecar:gateway
    container_name: zerotier-gateway
    privileged: true
    devices:
      - /dev/net/tun:/dev/net/tun
    # БЕЗ секции ports - только внутренний доступ
    networks:
      - backend
    environment:
      - ZT_NETWORK=ваш_id_сети
      - PORT_FORWARD=8989:10.121.15.16:8989
      - GATEWAY_MODE=true
      - ALLOWED_SOURCES=172.18.0.0/16  # Только из docker сети

networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
```

#### Пример конфигурации Nginx:
```nginx
# nginx.conf
upstream zerotier_backend {
    server zerotier-gateway:8989;  # Внутреннее имя контейнера:порт
}

server {
    listen 80;
    server_name вашдомен.com;

    location / {
        proxy_pass http://zerotier_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

#### Ключевые преимущества безопасности:
- **Ограниченная поверхность атаки**: Только 80/443 открыты в интернет
- **SSL терминация**: Обработка сертификатов на уровне прокси
- **Фильтрация запросов**: Фильтрация вредоносных запросов до достижения sidecar
- **Ограничение скорости**: Реализация ограничения скорости на уровне прокси
- **Защита от DDoS**: Прокси может обеспечить защиту от DDoS
- **Логирование**: Централизованное логирование доступа

### Лучшие практики
- **Никогда не выставляйте порты sidecar напрямую** - всегда используйте обратный прокси
- Используйте `GATEWAY_MODE=hybrid` только для тестирования/отладки
- Реализуйте правила потока ZeroTier для дополнительного контроля доступа
- Регулярные аудиты безопасности открытых сервисов
- Используйте сильную аутентификацию на целевых сервисах
- Настройте fail2ban или аналогичную систему предотвращения вторжений
- Регулярное резервное копирование конфигураций ZeroTier

## 📊 Мониторинг и устранение неполадок

### Проверка статуса контейнера
```bash
# Просмотр логов с информацией о режиме
docker logs zerotier-sidecar

# Проверка конфигурации
docker exec zerotier-sidecar cat /tmp/zt-sidecar/config.json

# Проверка статуса ZeroTier
docker exec zerotier-sidecar zerotier-cli listnetworks

# Проверка сетевых маршрутов
docker exec zerotier-sidecar ip route show
```

### Проверка переадресации портов
```bash
# Проверка прослушиваемых портов
docker exec zerotier-sidecar ss -tulpn

# Проверка правил iptables
docker exec zerotier-sidecar iptables -L -n -v
docker exec zerotier-sidecar iptables -t nat -L -n -v

# Проверка процессов socat (режим Gateway)
docker exec zerotier-sidecar ps aux | grep socat
```

### Распространенные проблемы и решения

**Проблема**: Соединения в режиме Gateway истекают по таймауту
- **Проверить**: Порты открыты в секции `ports` в `docker-compose.yml`
- **Проверить**: `GATEWAY_MODE=true` и назначение - это ZeroTier адрес
- **Проверить**: Firewall разрешает gateway порты на хосте

**Проблема**: Режим Backend не работает
- **Проверить**: Целевой сервис запущен в указанной Docker сети
- **Проверить**: ZeroTier клиент может достичь IP sidecar
- **Проверить**: Устройства авторизованы в ZeroTier Central

**Проблема**: Пользовательские маршруты не работают
- **Проверить**: Формат `FORCE_ZEROTIER_ROUTES`: `СЕТЬ:ШЛЮЗ`
- **Проверить**: IP шлюза достижим в ZeroTier сети
- **Проверить**: Целевая сеть правильно настроена

## 🔄 Миграция с v1.x на v2.x

### Обратная совместимость
Все конфигурации v1.x работают без изменений в v2.x:
```bash
# Конфигурация v1.x (все еще работает в v2.x)
ZT_NETWORK=ваш_id_сети
PORT_FORWARD=873:172.26.0.3:873
# GATEWAY_MODE по умолчанию 'false' (режим backend)
```

### Обновление до Gateway функций
```bash
# Добавление gateway функциональности к существующей установке
GATEWAY_MODE=true  # Включить режим gateway
ALLOWED_SOURCES=ваш.внешний.ip/32  # Ограничить доступ
```

## 🤝 Вклад в проект

Вклады приветствуются! Пожалуйста, не стесняйтесь отправлять Pull Request.

1. Сделайте форк репозитория
2. Создайте ветку функции (`git checkout -b feature/УдивительнаяФункция`)
3. Зафиксируйте изменения (`git commit -m 'Добавить УдивительнуюФункцию'`)
4. Отправьте в ветку (`git push origin feature/УдивительнаяФункция`)
5. Откройте Pull Request

## 📄 Лицензия

Этот проект лицензирован под лицензией MIT - см. файл [LICENSE](LICENSE) для подробностей.

## 🙏 Благодарности

- [ZeroTier](https://zerotier.com) за потрясающую платформу виртуализации сетей
- [Docker](https://docker.com) за технологию контейнеризации
- Сообществу открытого исходного кода за вдохновение и поддержку

## 📞 Поддержка

- 🐛 **Проблемы**: [GitHub Issues](https://github.com/alexbic/zerotier-sidecar/issues)
- 💬 **Обсуждения**: [GitHub Discussions](https://github.com/alexbic/zerotier-sidecar/discussions)
- 📖 **Документация**: Проверьте этот README и примеры в репозитории

---

⭐ **Если этот проект помог вам, пожалуйста, поставьте звезду!** ⭐
