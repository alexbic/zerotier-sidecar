# 🌐 ZeroTier Sidecar Core

[![Docker Pulls](https://img.shields.io/docker/pulls/alexbic/zerotier-sidecar)](https://hub.docker.com/r/alexbic/zerotier-sidecar)
[![Docker Image Size](https://img.shields.io/docker/image-size/alexbic/zerotier-sidecar/latest)](https://hub.docker.com/r/alexbic/zerotier-sidecar)
[![License](https://img.shields.io/github/license/alexbic/zerotier-sidecar)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/alexbic/zerotier-sidecar)](https://github.com/alexbic/zerotier-sidecar/stargazers)

[🇺🇸 English](README.md) | 🇷🇺 Русский

Мощный Docker контейнер, который действует как мост ZeroTier сети, обеспечивая безопасный проброс портов от ZeroTier сетей к Docker контейнерам. Идеально подходит для удаленного доступа к внутренним сервисам через защищенную сетевую mesh ZeroTier.

## 🐳 Docker Hub

**Готовый к использованию Docker образ**: [`alexbic/zerotier-sidecar`](https://hub.docker.com/r/alexbic/zerotier-sidecar)

```bash
docker pull alexbic/zerotier-sidecar:latest
```

## 🚀 Возможности

- **🔐 Безопасный проброс портов**: Гибкое сопоставление портов от ZeroTier сети к Docker контейнерам через зашифрованное соединение
- **📦 Простое развертывание**: Один Docker контейнер с простой конфигурацией
- **🌐 Интеграция ZeroTier и Docker**: Бесшовный мост между ZeroTier сетями и Docker контейнерами

## 🎯 Сценарии использования

- **🏠 Доступ к домашней лаборатории**: Безопасный доступ к домашним сервисам из любой точки
- **💾 Удаленное резервное копирование**: Включение rsync, NAS или сервисов резервного копирования через ZeroTier
- **🖥️ Разработка**: Удаленный доступ к средам разработки
- **🔧 Системное администрирование**: Удаленный SSH и управление сервисами
- **📡 IoT подключение**: Подключение IoT устройств и сервисов через сети

## 📋 Быстрый старт

### Использование Docker Compose (Рекомендуется)

1. **Создайте директорию проекта**:
```bash
mkdir zerotier-sidecar && cd zerotier-sidecar
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
# ID вашей ZeroTier сети
ZT_NETWORK=ваш_zerotier_network_id_здесь

# Проброс портов: ВНЕШНИЙ_ПОРТ:IP_НАЗНАЧЕНИЯ:ПОРТ_НАЗНАЧЕНИЯ
# Множественные порты разделяются запятой
PORT_FORWARD=873:172.26.0.3:873,22:172.26.0.4:22
```

4. **Развертывание**:
```bash
docker-compose up -d
```

### Использование Docker Run

```bash
docker run -d \
  --name zerotier-sidecar \
  --privileged \
  --device /dev/net/tun \
  --restart unless-stopped \
  --dns 8.8.8.8 \
  --cap-add NET_ADMIN \
  --cap-add SYS_ADMIN \
  -e ZT_NETWORK=ваш_network_id \
  -e PORT_FORWARD=873:172.26.0.3:873 \
  -v zerotier-data:/var/lib/zerotier-one \
  alexbic/zerotier-sidecar:latest
```

## ⚙️ Конфигурация

### Переменные окружения

| Переменная | Обязательная | Описание | Пример |
|------------|--------------|----------|--------|
| `ZT_NETWORK` | ✅ | ID ZeroTier сети | `ваш_zerotier_network_id_здесь` |
| `PORT_FORWARD` | ✅ | Правила проброса портов | `873:172.26.0.3:873,22:172.26.0.4:22` |

### Формат проброса портов

Переменная `PORT_FORWARD` использует формат: `ВНЕШНИЙ_ПОРТ:IP_НАЗНАЧЕНИЯ:ПОРТ_НАЗНАЧЕНИЯ`

- **ВНЕШНИЙ_ПОРТ**: Порт, доступный из ZeroTier сети
- **IP_НАЗНАЧЕНИЯ**: IP целевого Docker контейнера
- **ПОРТ_НАЗНАЧЕНИЯ**: Порт целевого контейнера

**Примеры**:
- Один порт: `873:172.26.0.3:873`
- Несколько портов: `873:172.26.0.3:873,22:172.26.0.4:22,80:172.26.0.5:8080`

## 🔧 Руководство по настройке

### 1. Создание ZeroTier сети

1. Перейдите на [ZeroTier Central](https://my.zerotier.com)
2. Создайте новую сеть
3. Запишите ваш Network ID (16-символьная hex строка)
4. Настройте параметры сети по необходимости

### 2. Настройка целевых сервисов

Убедитесь, что ваши целевые Docker сервисы находятся в той же сети что и sidecar:

```yaml
# docker-compose.yml вашего сервиса
version: "3.8"
services:
  my-service:
    image: my-service:latest
    networks:
      sidecar_net:
        external: true
```

### 3. Развертывание и тестирование

```bash
# Развертывание sidecar
docker-compose up -d

# Проверка логов
docker-compose logs -f

# Тестирование подключения из ZeroTier сети
ping SIDECAR_ZEROTIER_IP
telnet SIDECAR_ZEROTIER_IP 873
```

## 📊 Мониторинг и устранение неполадок

### Проверка статуса контейнера

```bash
# Просмотр логов
docker logs zerotier-sidecar

# Доступ к оболочке контейнера
docker exec -it zerotier-sidecar bash

# Проверка статуса ZeroTier
docker exec zerotier-sidecar zerotier-cli listnetworks

# Проверка конфигурации сети
docker exec zerotier-sidecar ip addr show
```

### Частые проблемы

**Проблема**: `join connection failed`
- **Решение**: Проверьте интернет подключение и настройки файрвола

**Проблема**: Проброс портов не работает
- **Решение**: Проверьте IP целевого сервиса и убедитесь что сервисы в одной Docker сети

**Проблема**: Не могу достичь ZeroTier IP
- **Решение**: Убедитесь что устройство авторизовано в ZeroTier Central

## 🏗️ Архитектура

```
┌─────────────────┐    ZeroTier     ┌─────────────────┐
│  Удаленный      │◄──────────────►│  Sidecar        │
│  клиент         │                │  контейнер      │
│ (Дом/Офис)      │                └─────────────────┘
└─────────────────┘                         │
                                   Docker Network
                                            │
                                   ┌─────────────────┐
                                   │  Целевой сервис │
                                   │  (rsync/ssh/etc)│
                                   └─────────────────┘
```

## 🔐 Соображения безопасности

- **Изоляция сети**: Используйте выделенные Docker сети для лучшей безопасности
- **Авторизация ZeroTier**: Всегда авторизуйте устройства в ZeroTier Central
- **Правила файрвола**: Настройте соответствующие правила файрвола для целевых сервисов
- **Контроль доступа**: Используйте flow правила ZeroTier для дополнительного контроля доступа

## 🤝 Вклад в проект

Вклады приветствуются! Пожалуйста, не стесняйтесь отправлять Pull Request.

1. Сделайте fork репозитория
2. Создайте ветку для вашей функции (`git checkout -b feature/УдивительнаяФункция`)
3. Зафиксируйте ваши изменения (`git commit -m 'Добавить УдивительнуюФункцию'`)
4. Отправьте в ветку (`git push origin feature/УдивительнаяФункция`)
5. Откройте Pull Request

## 📄 Лицензия

Этот проект лицензирован под лицензией MIT - смотрите файл [LICENSE](LICENSE) для подробностей.

## 🙏 Благодарности

- [ZeroTier](https://zerotier.com) за потрясающую платформу сетевой виртуализации
- [Docker](https://docker.com) за технологию контейнеризации
- Сообществу открытого исходного кода за вдохновение и поддержку

## 📞 Поддержка

- 🐛 **Проблемы**: [GitHub Issues](https://github.com/alexbic/zerotier-sidecar/issues)
- 💬 **Обсуждения**: [GitHub Discussions](https://github.com/alexbic/zerotier-sidecar/discussions)

---

⭐ **Если этот проект помог вам, пожалуйста, поставьте звезду!** ⭐
