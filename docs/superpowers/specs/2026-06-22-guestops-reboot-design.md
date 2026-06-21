# Projekt: inicjacja rebootu po patchowaniu GuestOps

Data: 2026-06-22

## Cel

Dodac do orkiestratora opcjonalna faze inicjacji rebootu VM po instalacji aktualizacji, jezeli wynik patchowania wskazuje `rebootRequired = true`. Reboot ma byc uruchamiany przez vSphere Guest Operations wewnatrz systemu goscia, po osobnym potwierdzeniu administratora.

Mechanizm nie ma monitorowac powrotu VM po restarcie. Po zainicjowaniu rebootu operator uruchamia skrypt ponownie, jezeli chce zweryfikowac stan po restarcie albo wykonac kolejny cykl aktualizacji.

## Zalozenia

- Runtime pozostaje Windows PowerShell 5.1 na stepping stone.
- WinRM, PSSession, `Invoke-VMScript` i `Copy-VMGuestFile` nadal nie sa uzywane.
- Reboot jest inicjowany w gosciu przez GuestOps, najprosciej przez `shutdown.exe /r /t 0 /c "PatchingGuestOps reboot after updates"`.
- Skrypt nie czeka na wylaczenie, wlaczenie, powrot VMware Tools ani gotowosc systemu po restarcie.
- `-SkipConfirmation` nigdy nie pomija potwierdzenia rebootu.
- Istniejacy `-ThrottleLimit` ogranicza rowniez rownolegla inicjacje rebootu.
- Blad inicjacji rebootu po zatwierdzeniu przez administratora jest bledem operacyjnym i ustawia koncowy exit code na `1`.

## Poza zakresem

- Reboot po stronie vCenter albo VMware bez komendy w gosciu.
- Cykliczne sprawdzanie, czy VM wymaga rebootu.
- Monitorowanie, czy VM faktycznie wstala po restarcie.
- Automatyczne ponawianie patchowania po restarcie.
- Osobny parametr typu `-RebootThrottleLimit`.
- Bezobslugowe pomijanie promptu rebootu.

## Trigger

Nie ma osobnego pollingu rebootu. Triggerem jest zakonczona faza `apply` i wynik statusu agenta dla kazdej VM:

- `installResult.rebootRequired` zwrocone przez Windows Update Agent;
- albo `pendingRebootAfter.isPending` wykryte przez agenta po instalacji.

Orkiestrator juz przelicza te wartosci do pola `rebootRequired` w wyniku apply. Tylko VM z `rebootRequired = true` wchodza do fazy inicjacji rebootu.

## Potwierdzenie operatora

Po zakonczeniu apply i wygenerowaniu raportu skrypt pokazuje liste VM wymagajacych rebootu. Jezeli lista jest pusta, faza rebootu jest pomijana.

Jezeli lista nie jest pusta, skrypt wymaga osobnej akceptacji administratora. Zalecany prompt:

```text
Reboot required on 3 VM(s):
- VM01
- VM02
- VM03

Initiate guest reboot now? Type REBOOT to continue:
```

Tylko dokladny tekst `REBOOT` uruchamia reboot. Kazda inna odpowiedz oznacza pominiecie rebootu. Pominiecie przez operatora nie zmienia wyniku patchowania na blad, ale musi byc widoczne w raporcie.

## Przeplyw

1. Orkiestrator wykonuje dotychczasowy flow: discovery, selection, patch plan, confirmation, apply.
2. Orkiestrator zapisuje standardowy final report dla patchowania.
3. Orkiestrator filtruje wyniki apply do VM z `rebootRequired = true`.
4. Jezeli lista jest pusta, skrypt konczy sie zgodnie z dotychczasowa semantyka apply.
5. Jezeli lista nie jest pusta, skrypt wyswietla liste i pyta o osobne potwierdzenie rebootu.
6. Jezeli administrator nie wpisze `REBOOT`, skrypt zapisuje, ze reboot zostal pominiety przez operatora, i konczy sie zgodnie z wynikiem apply.
7. Jezeli administrator wpisze `REBOOT`, skrypt inicjuje reboot tylko dla VM z `rebootRequired = true`.
8. Inicjacja rebootu jest ograniczana przez `-ThrottleLimit`.
9. Skrypt zapisuje wynik per VM i nie sprawdza stanu VM po restarcie.

## Rownoleglosc

Faza rebootu uzywa istniejacego `-ThrottleLimit`.

- Przy `-ThrottleLimit 1` rebooty sa inicjowane sekwencyjnie.
- Przy `-ThrottleLimit N` skrypt inicjuje reboot maksymalnie na `N` VM jednoczesnie.
- Limit dotyczy tylko uruchomienia komendy rebootu, nie czekania na powrot VM.

Nie dodajemy `-RebootThrottleLimit`, bo na tym etapie nie ma potrzeby rozszerzac kontraktu CLI. Jezeli operator chce ostrozniejszy reboot, ustawia nizszy `-ThrottleLimit` dla calego uruchomienia.

## Raportowanie

Skrypt powinien zapisac osobny artefakt `reboot-actions.json` w katalogu cyklu. Artefakt zawiera wynik per VM:

- `vmName`;
- `rebootRequired`;
- `action`: `Initiated`, `SkippedByOperator` albo `Failed`;
- `errorMessage`, jezeli inicjacja rebootu sie nie udala.

`summary.md` powinien zawierac sekcje z wynikiem rebootu:

- VM, na ktorych zainicjowano reboot;
- VM, na ktorych reboot zostal pominiety przez operatora;
- VM, na ktorych inicjacja rebootu sie nie udala.

Jezeli inicjacja rebootu sie nie udala, raport musi wskazac konkretna VM i komunikat bledu. Skrypt nie raportuje, czy VM faktycznie wstala po restarcie, bo to jest poza zakresem.

## Exit code

Semantyka koncowego exit code:

- Brak VM wymagajacych rebootu: bez zmian wzgledem dotychczasowego apply.
- Reboot wymagany, ale operator go nie zatwierdzil: bez zmian wzgledem dotychczasowego apply.
- Reboot zatwierdzony i zainicjowany na wszystkich wskazanych VM: bez zmian wzgledem dotychczasowego apply.
- Reboot zatwierdzony, ale inicjacja nie udala sie na przynajmniej jednej VM: exit code `1`.

Blad inicjacji rebootu nie zmienia faktu, ze instalacja aktualizacji mogla sie udac. Jest jednak bledem potwierdzonej operacji administracyjnej, dlatego powinien ustawic exit code `1`.

## Testy

Minimalny zakres testow:

- brak promptu rebootu, gdy zadna VM nie ma `rebootRequired = true`;
- prompt rebootu pojawia sie, gdy co najmniej jedna VM ma `rebootRequired = true`;
- `-SkipConfirmation` nie pomija promptu rebootu;
- tylko dokladny tekst `REBOOT` zatwierdza reboot;
- VM bez `rebootRequired = true` nie trafiaja do fazy rebootu;
- `-ThrottleLimit` ogranicza liczbe rownoleglych inicjacji rebootu;
- pominiecie rebootu przez operatora jest raportowane bez exit code `1`;
- blad inicjacji rebootu jest raportowany per VM i ustawia exit code `1`.

Testy powinny pozostac mozliwie offline tam, gdzie dotycza filtrowania, potwierdzenia, raportowania i exit code. Cienka warstwa GuestOps moze byc sprawdzana statycznie przez obecny mechanizm `Invoke-StaticChecks.ps1`.

## Granice implementacji

Zmiana powinna byc chirurgiczna:

- bez zmian w modelu WUA instalujacym aktualizacje, jezeli obecne pola `installResult.rebootRequired` i `pendingRebootAfter.isPending` wystarcza;
- bez przenoszenia logiki rebootu do agenta WUA;
- bez refaktoryzacji flow discovery, selection i patch plan;
- z wykorzystaniem istniejacych helperow GuestOps i istniejacego mechanizmu throttlingu tam, gdzie to praktyczne;
- z raportowaniem rebootu jako dodatkowego wyniku po apply, a nie jako warunku samej instalacji aktualizacji.
