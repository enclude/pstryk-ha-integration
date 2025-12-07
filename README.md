# Pstryk Home Assistant Integration

## Co właściwie to robi?

Ten skrypt integruje API cenowe Pstryk z Home Assistant, zapewniając monitorowanie cen energii w czasie rzeczywistym z inteligentnym systemem cache'owania i obsługą limitów API.

### 🔋 Główne funkcje:

1. **Monitorowanie cen energii:**
   - Pobiera aktualne i przyszłe ceny energii (zakup/sprzedaż) z api.pstryk.pl
   - Określa czy obecna/następna godzina ma tanie lub drogie stawki
   - Oblicza czy obecna/następna godzina jest najtańsza w danym dniu
   - Ranking cenowy obecnej godziny (0=najtańsza, 23=najdroższa)

2. **Inteligentny system cache'owania:**
   - Dwupoziomowy cache: dane + znaczniki czasowe
   - Cache wygasa po 55 minutach (konfigurowalne)
   - Kodowanie base64 zapobiega korupcji danych JSON
   - Automatyczne czyszczenie uszkodzonych/starych wpisów cache

3. **Ochrona przed limitami API:**
   - Wykrywa ograniczenia API (komunikat: "Żądanie zostało zdławione")
   - Wykorzystuje cache jako fallback przy ograniczeniach
   - Używa najnowszego dostępnego cache jeśli bieżący jest niedostępny

4. **Wsparcie konteneryzacji:**
   - Może czytać konfigurację ze zmiennych środowiskowych
   - Gotowy do uruchomienia w Docker z odpowiednim montowaniem volumów
   - Obsługuje zarówno argumenty skryptu jak i zmienne środowiskowe

5. **Integracja z Home Assistant:**
   - Aktualizuje 11 sensorów na uruchomienie
   - Ranking cenowy w skali 0-23 dla precyzyjnych automatyzacji
   - Prawidłowe jednostki (PLN/kWh) i zarządzanie stanem
   - Logowanie debug dla rozwiązywania problemów

### 📊 Sensory tworzone w Home Assistant:

- `sensor.pstryk_script_current_buy` - Obecna cena sprzedaży energii przez Pstryk (cena po której kupujemy)
- `sensor.pstryk_script_current_sell` - Obecna cena zakupu energii przez Pstryk (cena po której sprzedajemy)
- `sensor.pstryk_script_current_is_cheap` - Czy obecna cena jest tania (`true`/`false`)
- `sensor.pstryk_script_current_is_expensive` - Czy obecna cena jest droga (`true`/`false`)
- `sensor.pstryk_current_cheapest` - Czy obecna godzina jest najtańsza dzisiaj (`true`/`false`)
- `sensor.pstryk_current_index` - **Ranking cenowy obecnej godziny (0-23)** gdzie `0` = najtańsza, `23` = najdroższa
- `sensor.pstryk_script_next_buy` - Następna cena sprzedaży energii przez Pstryk
- `sensor.pstryk_script_next_sell` - Następna cena zakupu energii przez Pstryk
- `sensor.pstryk_script_next_is_cheap` - Czy następna cena będzie tania (`true`/`false`)
- `sensor.pstryk_script_next_is_expensive` - Czy następna cena będzie droga (`true`/`false`)
- `sensor.pstryk_next_cheapest` - Czy następna godzina będzie najtańsza dzisiaj (`true`/`false`)

### � System rankingu cenowego

Sensor `pstryk_current_index` zapewnia precyzyjny ranking cen na skalę 0-23:

- **Wartość 0:** Obecna godzina ma najniższą cenę w całej dobie
- **Wartość 1-22:** Pozycja w rankingu (1 = druga najniższa, 22 = druga najwyższa)
- **Wartość 23:** Obecna godzina ma najwyższą cenę w całej dobie

**Przykład zastosowania w automatyzacjach:**
```yaml
# Uruchom pralką tylko gdy cena jest w TOP 6 najtańszych godzin
automation:
  - alias: "Uruchom pralkę przy niskich cenach"
    trigger:
      - platform: numeric_state
        entity_id: sensor.pstryk_current_index
        below: 6  # TOP 6 najtańszych godzin (0-5)
    action:
      - service: switch.turn_on
        entity_id: switch.washing_machine
```

### �🔧 Wymagania systemowe:

- `curl` - żądania API i aktualizacje Home Assistant
- `jq` - parsowanie JSON i ekstrakcja danych
- `base64` - kodowanie/dekodowanie cache
- `date` - obsługa znaczników czasowych i wygasania cache


## 🔑 Pozyskiwanie tokenów

### Jak pobrać token z Home Assistant
1. Przejdź do profilu (prawy dolny róg) → Security → Long-lived access tokens
2. Kliknij "Create Token"
3. Nadaj nazwę (np. "Pstryk Integration") 
4. Skopiuj wygenerowany token

<img src="files/image.png"/>

### Jak pobrać token z Pstryk
1. Otwórz aplikację mobilną Pstryk
2. Przejdź do: Konto (lewy dolny róg) → Urządzenia i integracje → API
3. Kliknij "Wygeneruj nowy"
4. Skopiuj wygenerowany token API

<img src="files/image-1.png" width="165"/> <img src="files/image-2.png" width="165"/> <img src="files/image-3.png" width="165"/> 

## 🔄 Jak działa przepływ danych

1. **Sprawdzenie świeżości cache** (< 55 minut) → Użyj cache jeśli świeży
2. **Jeśli cache przestarzały lub brak** → Wywołaj API Pstryk
3. **Jeśli API sukces** → Zapisz do cache + zaktualizuj Home Assistant
4. **Jeśli API ograniczone** → Użyj przestarzałego cache jako fallback
5. **Ekstrakcja danych cenowych** dla obecnej/następnej godziny
6. **Obliczenie porównań najtańszej godziny**
7. **Aktualizacja wszystkich sensorów** Home Assistant nowymi danymi

## 🛠️ Rozwiązywanie problemów

### Problemy z cache
```bash
# Sprawdź zawartość cache
cat /var/tmp/pstryk_cache_timestamps.txt
base64 -d /var/tmp/pstryk_cache.txt | head

# Wyczyść cache
rm -f /var/tmp/pstryk_cache*.txt
```

### Problemy z API
```bash
# Test bezpośredniego wywołania API
curl -sG \
  -H "Authorization: TWÓJ_TOKEN" \
  "https://api.pstryk.pl/integrations/pricing/" \
  --data-urlencode "resolution=hour"
```

### Debug logów
Skrypt wypisuje szczegółowe logi na stderr. Przekieruj je do pliku:
```bash
./ha.sh "TOKEN" "HA_IP" "HA_TOKEN" 2> debug.log
```

### Częste błędy
- **"Żądanie zostało zdławione"** → API rate limit, skrypt automatycznie użyje cache
- **"jq: parse error"** → Uszkodzone dane cache, wyczyść pliki cache
- **Brak aktualizacji sensorów** → Sprawdź token HA i dostępność endpointu 

## 🚀 Sposób użycia

### Instalacja podstawowa (tradycyjna)
1. **Zainstaluj wymagane pakiety:**
   ```bash
   apt install -y curl jq
   ```

2. **Umieść plik `ha.sh` w wybranym katalogu:**
   ```bash
   mkdir -p /opt/pstryk-ha
   cp ha.sh /opt/pstryk-ha/
   chmod +x /opt/pstryk-ha/ha.sh
   ```

3. **Dodaj zadanie do crontab (uruchamianie co godzinę):**
   ```bash
   crontab -e
   # Dodaj linię:
   1 * * * * /opt/pstryk-ha/ha.sh "TWÓJ_PSTRYK_TOKEN" "http://homeassistant.local:8123" "TWÓJ_HA_TOKEN"
   ```

### Uruchomienie w kontenerze Docker
1. **Utwórz plik docker-compose.yml:**
   ```yaml
   version: '3.8'
   services:
     pstryk-ha:
       image: pstryk-ha:latest
       environment:
         - API_TOKEN=TWÓJ_PSTRYK_TOKEN
         - HA_IP=http://homeassistant.local:8123
         - HA_TOKEN=TWÓJ_HA_TOKEN
       volumes:
         - /var/tmp:/var/tmp  # Dla trwałości cache
       restart: unless-stopped
   ```

2. **Lub uruchom bezpośrednio:**
   ```bash
   docker run --rm \
     -e API_TOKEN="TWÓJ_PSTRYK_TOKEN" \
     -e HA_IP="http://homeassistant.local:8123" \
     -e HA_TOKEN="TWÓJ_HA_TOKEN" \
     -v /var/tmp:/var/tmp \
     pstryk-ha:latest
   ```

### Konfiguracja parametrów
- **Argumenty skryptu:** `./ha.sh "PSTRYK_TOKEN" "HA_IP" "HA_TOKEN"`
- **Zmienne środowiskowe:** `API_TOKEN`, `HA_IP`, `HA_TOKEN` (dla kontenerów)
- **Lokalizacja cache:** `/var/tmp/pstryk_cache.txt` + `/var/tmp/pstryk_cache_timestamps.txt`
- **Czas wygaśnięcia cache:** 55 minut (można zmienić w skrypcie: `CACHE_MAX_AGE_MINUTES`)

### Testowanie
```bash
# Test pojedynczy
./ha.sh "TWÓJ_TOKEN" "http://homeassistant.local:8123" "TWÓJ_HA_TOKEN"

# Sprawdzenie cache
ls -la /var/tmp/pstryk_cache*
cat /var/tmp/pstryk_cache_timestamps.txt
```