# AudioBookPlayer (abPlayer)
приложение для Mac (Apple Silicon), iPhone, iPad которое позволит вам бесплатно слушать и скачивать аудио книги.

За основу взят проект https://github.com/AlexDev505/AudioBookPlayer. Но так как Windows-app это не путь самуря, то проект полностью переработан на Swift.

## Что готово
- приложение abPlayer для macOS
- приложение abPlayer для iOS/iPadOS
-- работает поиск, скачивание и прослушивание книг с сайтов akniga.org, knigavuhe.org, izib.uk, yakniga.org, librivoxaudio.

## Скриншоты
### macOS
<img width="610" height="363" alt="mac_поиск" src="https://github.com/user-attachments/assets/5e484327-f147-4cfc-8748-ecf81049a270" /><img width="615" height="371" alt="mac_загрузки" src="https://github.com/user-attachments/assets/274b626b-2cc9-4691-a61a-90618c13d78c" />
<img width="611" height="364" alt="mac_библиотека" src="https://github.com/user-attachments/assets/47335baa-da27-43d3-8abe-2c94e8d89998" /><img width="610" height="363" alt="mac_воспроизведение" src="https://github.com/user-attachments/assets/14f6f16b-3dac-45cc-9430-8dbf32846842" />

### iOS/iPadOS
<img width="290" height="630" alt="ios_библиотека" src="https://github.com/user-attachments/assets/e74cea7b-48ef-4506-b2b9-8a8ad85e75d7" /><img width="290" height="630" alt="ios_загрузка" src="https://github.com/user-attachments/assets/101302eb-612f-4ccf-898e-605dfed0a0fe" />

<img width="290" height="630" alt="ios_воспроизведение" src="https://github.com/user-attachments/assets/214e29ae-04db-4d48-a531-87a7f3d26871" /><img width="290" height="630" alt="ios_настройки" src="https://github.com/user-attachments/assets/62268442-67bd-427d-9d80-c80b337bccea" />

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


## Последующая поддержка и доработка - при наличии большого интереса и свободного времени. Если нужны аппы - берите в релизах, если есть желание самостоятельно что-то допилить/подправить как говорится - "вэлкам!"
