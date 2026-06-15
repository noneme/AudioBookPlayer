# AudioBookPlayer (abPlayer)
приложение для Mac (Apple Silicon), iPhone, iPad которое позволит вам бесплатно слушать и скачивать аудио книги.

За основу взят проект https://github.com/AlexDev505/AudioBookPlayer. Но так как Windows-app это не путь самуря, то проект полностью переработан на Swift.

## Что готово
- приложение abPlayer для macOS
- приложение abPlayer для iOS/iPadOS
-- работает поиск, скачивание и прослушивание книг с сайтов akniga.org, knigavuhe.org, izib.uk, yakniga.org, librivoxaudio.

Последующая поддержка и доработка - при наличии большого интереса и свободного времени. Если нужны аппы - берите в релизах, если есть желание самостоятельно что-то допилить/подправить как говорится - "вэлкам!"

## Предварительные требования перед сборкой:
- Xcode с настроенным Apple ID (для подписи/provisioning).
- Уникальный iOS bundle identifier.
- Ваш Apple Developer Team ID.

## Сборка `.app` для macOS из терминала

```bash
xcodebuild -project /abPlayer/abPlayer.xcodeproj \
-scheme abPlayer \
-configuration Release \
-arch arm64 \
ONLY_ACTIVE_ARCH=NO \
clean build
```

## Сборка iOS архива (`.xcarchive`) и экспорт IPA

### Создание полноценной iOS App target в Xcode (обязательно для IPA)

1. Откройте `/abPlayer/abPlayer.xcodeproj` в Xcode.
2. В настройках target проекта:
   - Signing: ваша Team + уникальный bundle id
3. Один раз соберите и запустите на симуляторе/устройстве.
4. Создайте архив через меню Xcode: **Product -> Archive** (выберите схему вашей iOS app).
5. Экспортируйте IPA используя этот app archive выполнив команду:

```bash
abPlayerSwift/scripts/export_ios_ipa.sh
```

Пути вывода по умолчанию:
- Папка экспорта: `abPlayerSwift/build/ios/export`
