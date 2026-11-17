# Migração da interface Windows para WinUI 3

Plano de trabalho da branch `windows-winui3`. Ela parte de
`windows-native-tabbar` no commit `a2a36c4`, o mesmo do release
`windows-v1.4.1.3`, onde a interface usa WinUI 2.

Este documento diz o que existe hoje, o que muda em cada peça, que decisões
precisam ser tomadas antes de escrever código e em que ordem fazer o
trabalho. Nada aqui foi implementado ainda. O que está marcado **verificar**
é suposição que precisa de uma prova antes de virar plano.

## Por que migrar

- **Futuro da plataforma.** O WinUI 2 está em manutenção, e o 2.8 é a
  última linha; recursos novos só saem no WinUI 3 (Windows App SDK).
- **Popups.** No WinUI 2, uma ilha XAML corta tudo o que passa dos limites
  do próprio HWND. É por isso que o menu de perfis vive numa segunda ilha,
  numa janela de topo própria. O WinUI 3 tem popups em janela própria, o
  que pode eliminar esse truque (**verificar**, ver "Riscos").
- **Uma pilha só.** Hoje a interface é metade XAML (a barra de abas e o
  menu de perfis) e metade Win32 (paleta, busca, renomear, menus de
  contexto, overview). Portar para WinUI 3 é a oportunidade de trazer a
  outra metade para XAML com a mesma aparência Fluent.

O que **não** muda: o visual. O `TabView` do WinUI 3 é o mesmo controle
Fluent do WinUI 2.8.

## O que existe hoje

### A DLL da barra de abas

`dist/windows/tabbar/ghostty-tabbar/ghostty_tabbar.cpp` (cerca de 2700
linhas de C++/WinRT, WinUI 2) com a ABI C em `ghostty_tabbar.h`. O Zig a
consome por `src/apprt/win32/tabbar.zig`.

| Peça | Tecnologia hoje |
|---|---|
| Faixa de abas (`TabView`), `+`, `⌄`, arrastar e reordenar | WinUI 2 numa ilha (`Windows.UI.Xaml.Hosting.DesktopWindowXamlSource`) |
| Visual das abas | Modelo do próprio WinUI, com as cores postas nos `ThemeDictionaries` de cada item, como no Windows Terminal |
| Botões de legenda (minimizar, maximizar, fechar, overview) | XAML na mesma ilha, com glifos Segoe Fluent |
| Menu de perfis (novos shells, Configurações, Paleta) | Segunda ilha XAML numa janela de topo, pré-montada e estacionada fora da tela |
| Ícones dos shells | `CachedShellIcon`: ícone do executável virando bitmap XAML |
| Tema (cores vindas da config do Ghostty) | `ResourceDictionary` próprio de cada barra, mesclado no `Grid` raiz |
| Paleta de comandos e pedidos de texto (`input_*`) | Win32 puro: `EDIT` + `LISTBOX` numa janela popup |
| Menu de contexto (`popup_menu`) | Win32 puro: `CreatePopupMenu` + `TrackPopupMenu` |
| Notificações (`notify`) | `Windows.UI.Notifications` (WinRT do sistema, não do WinUI) |
| Progresso na barra de tarefas (`set_progress`) | `ITaskbarList3` |
| Teclado na ilha (`pretranslate`) | `IDesktopWindowXamlSourceNative2::PreTranslateMessage` |

As exportações da ABI que precisam sobreviver à migração estão todas em
`ghostty_tabbar.h`: `create`, `destroy`, `height`, `resize`,
`pretranslate`, `add_tab`, `remove_tab`, `move_tab`, `set_title`,
`set_tab_icon`, `set_selected`, `add_profile`, `clear_profiles`,
`rendered`, `set_theme`, `set_maximized`, `input_show`,
`input_set_items`, `input_set_status`, `input_hide`, `input_visible`,
`popup_menu`, `notify` e `set_progress`, além dos callbacks de
`GhosttyTabBarCallbacks` e `GhosttyInputCallbacks`.

### O resto da interface, no Zig

`src/apprt/win32.zig`:

- **Janela:** moldura Win32 com área de cliente estendida sobre a
  legenda (`WM_NCCALCSIZE`). A faixa da barra fica no topo, e uma janela
  filha OpenGL (`GhosttyGLClass`) fica abaixo dela.
- **Terminal:** cada painel renderiza em OpenGL numa textura, e a janela
  compõe os painéis com `glBlitFramebuffer`. Isso inclui divisórias,
  painéis sem foco esmaecidos e o overview, que desenha cada aba em escala.
- **Overview:** os quadros vêm do GL; os rótulos são janelas filhas GDI
  (`labelWndProc`).
- **Busca e renomear:** usam a mesma `input_*` da DLL (Win32).
- **Terminal rápido:** uma janela de topo a mais, com a mesma barra.

### Distribuição

- **MSIX** (`dist/windows/msix`): declara `PackageDependency` em
  `Microsoft.UI.Xaml.2.8` e em `Microsoft.VCLibs.140.00.UWPDesktop`.
- **setup.exe** (`dist/windows/installer`): leva `Microsoft.UI.Xaml.dll`,
  a pasta de recursos e o `resources.pri` do WinUI 2 ao lado do exe (+16 MB)
  e funciona sem pacote.
- **Dependências:** `dist/windows/tabbar/fetch-deps.ps1` baixa **só** o
  WinUI 2 (e o WebView2, cujos metadados o WinUI 2 referencia) e gera
  apenas a projeção `projection/`. Os pacotes do Windows App SDK 1.8 em
  `packages/` e a projeção `projection-winui3/` vieram de uma prova feita à
  mão (`poc3`). O script não os reproduz.

### O que já foi provado em WinUI 3

- **`dist/windows/tabbar/poc3/`:** `TabView` do WinUI 3 numa janela Win32,
  **sem pacote**, com o bootstrapper do Windows App SDK
  (`MddBootstrapInitialize2`), `DispatcherQueueController`, uma subclasse
  de `Application` e `Microsoft.UI.Xaml.Hosting.DesktopWindowXamlSource`
  inicializado com `GetWindowIdFromWindow`. Funcionou.
- **`dist/windows/tabhost/`:** a tentativa em C# que foi abandonada. O
  motivo foi a ordem de inicialização (`RPC_E_WRONG_THREAD`), não uma
  limitação da plataforma. A lição vale igual para o WinUI 3: primeiro o
  construtor base de `Application`, depois
  `WindowsXamlManager::InitializeForCurrentThread()`, e só então
  `Resources()`.

## Decisões a tomar antes de começar

### D1. Até onde vai a migração

| Opção | O que é | Custo |
|---|---|---|
| **A. Trocar a DLL** | Mesma janela Win32, mesmo GL; só a barra (e os popups dela) passam de WinUI 2 para WinUI 3, mantendo a ABI C | O menor. O Zig quase não muda |
| **B. Interface inteira em XAML** | A, mais paleta, busca, renomear, menus de contexto e rótulos do overview em XAML. O terminal continua em GL | Médio. Exige resolver o *airspace* (ver Riscos) |
| **C. Arquitetura do Windows Terminal** | A janela toda vira uma ilha XAML, e o terminal renderiza num `SwapChainPanel` | O maior. Exige um renderizador Direct3D no lugar do OpenGL |

**Recomendação:** fazer **A** e depois **B**, em fases (abaixo). **C** fica
fora do escopo desta branch. Ela mexe no renderizador do núcleo, não só na
interface, e o noctty (um port de Ghostty para Windows) tem um backend
D3D11 opcional cujos autores não afirmam ganho sobre OpenGL.

### D2. Como o runtime chega ao usuário

O WinUI 3 vem do Windows App Runtime, que não faz parte do Windows.

| Opção | Como | Tamanho | Observação |
|---|---|---|---|
| **Dependente do framework** | MSIX: `PackageDependency` em `Microsoft.WindowsAppRuntime.1.8`. setup.exe: bootstrapper + instalar o runtime se faltar, como faz o komorebi-switcher | Mínimo no nosso pacote | O usuário baixa o runtime uma vez; é compartilhado com outros apps |
| **Self-contained** | Os DLLs do runtime vão junto do exe (`WindowsAppSDKSelfContained`) | +~42 MB (WinUI 27,7 MB + InteractiveExperiences 13,6 MB + Foundation, medidos em `packages/`) | Nada para instalar; o pacote cresce de ~19 para ~60 MB |

**Recomendação:** dependente do framework. É o que o komorebi-switcher faz,
e o `ghostty.iss` já tem o padrão a copiar (`TryCreatePackageDependency`
para testar, e download do instalador oficial com hash fixo se faltar).

### D3. Versões

- **Windows App SDK 1.8:** é o que está em `packages/` e o que o `poc3`
  provou. Fixar a versão no `fetch-deps.ps1`.
- **Windows mínimo:** o WinUI 3 exige Windows 10 1809 (17763). As ilhas
  já exigem 1903 (18362) hoje (`MinVersion` no `ghostty.iss`), então nada
  muda para o usuário.

## Trabalho por área

### 1. Dependências e build

- `fetch-deps.ps1`: baixar os pacotes `Microsoft.WindowsAppSDK.*` 1.8 que
  hoje estão em `packages/` à mão e gerar `projection-winui3/` com o
  `cppwinrt`, como já faz para o WinUI 2. Remover o WinUI 2 e o WebView2
  ao final da migração.
- `ghostty-tabbar/build.bat`:
  - incluir `projection-winui3`, `Foundation\include` e
    `InteractiveExperiences\include` (o `Microsoft.UI.Interop.h` de
    `GetWindowIdFromWindow` é um header escrito à mão; o `poc3/build.bat`
    tem o caminho);
  - linkar `Microsoft.WindowsAppRuntime.Bootstrap.lib`;
  - copiar `Microsoft.WindowsAppRuntime.Bootstrap.dll` para junto da DLL.
- O CI (`release-windows.yml`) já roda `fetch-deps.ps1` e `build.bat`; só
  muda o que eles fazem.

### 2. Inicialização e ciclo de vida

Hoje a DLL é dependência de carga do `ghostty.exe` e inicializa o XAML no
primeiro `ghostty_tabbar_create`. No WinUI 3:

- `MddBootstrapInitialize2` precisa rodar antes de qualquer chamada
  WinRT do Windows App SDK, e só sem pacote: o MSIX resolve o runtime pela
  `PackageDependency`. Proposta: uma exportação nova,
  `ghostty_tabbar_init()`, chamada no `App.init` do `win32.zig`, e
  `ghostty_tabbar_shutdown()` (`MddBootstrapShutdown`) no encerramento.
- `DispatcherQueueController::CreateOnCurrentThread()` na thread da UI,
  antes de criar o `Application`. O WinUI 3 não usa `CoreDispatcher`.
- A subclasse de `Application` muda de namespace e mantém a ordem:
  construtor base, `WindowsXamlManager::InitializeForCurrentThread()`,
  depois `Resources()`, mesclando `XamlControlsResources` e implementando
  `IXamlMetadataProvider` por `XamlControlsXamlMetaDataProvider`. O
  `poc3/main.cpp` tem a versão funcionando.
- Revalidar a correção da segunda janela (cada barra com seu
  `theme_dict`, mesclado no `Grid` raiz e não no `Application`). No WinUI 2,
  mesclar no `Application` derrubava o processo ao abrir a segunda janela.

### 3. A ilha

| WinUI 2 (hoje) | WinUI 3 |
|---|---|
| `Windows.UI.Xaml.Hosting.DesktopWindowXamlSource` | `Microsoft.UI.Xaml.Hosting.DesktopWindowXamlSource` |
| `IDesktopWindowXamlSourceNative::AttachToWindow(hwnd)` | `Initialize(GetWindowIdFromWindow(hwnd))` |
| `get_WindowHandle` + `SetWindowPos` para mover e mostrar | `SiteBridge().MoveAndResize(...)` e `SiteBridge().Show()` |
| `IDesktopWindowXamlSourceNative2::PreTranslateMessage` | O Windows App SDK 1.4+ espera que o loop de mensagens passe pelo pré-tradutor de conteúdo dele; **verificar** a API exata antes de reescrever o `ghostty_tabbar_pretranslate` |

O truque de deixar a ilha visível com `SWP_SHOWWINDOW`, registrado no
README da barra, provavelmente some, porque a ponte tem `Show()`.
**Verificar.**

### 4. O código XAML e C++/WinRT

- **Namespaces:** `Windows::UI::Xaml::*` → `Microsoft::UI::Xaml::*`. O
  `TabView` já está em `Microsoft::UI::Xaml::Controls` nos dois.
  `Windows::UI::Color`, `Windows::Foundation::*` e
  `Windows::UI::Xaml::Interop::TypeName` continuam (o `poc3` mostra o
  último).
- **Includes:** trocar os `winrt/Windows.UI.Xaml.*.h` pelos
  `winrt/Microsoft.UI.Xaml.*.h`, e acrescentar `Microsoft.UI.Dispatching`,
  `Microsoft.UI.Content` e `Microsoft.UI.Interop`.
- **Cores das abas:** já não há modelo copiado. Desde `3db6c65` as abas
  usam o modelo do próprio WinUI e recebem as cores como no Windows
  Terminal: chaves `TabViewItemHeaderBackground*` e `TabViewBorderBrush`
  nos `ThemeDictionaries` de cada item (`ApplyTabColors`), seguidas da
  releitura forçada (`RefreshTabVisual`). No WinUI 3, verificar no
  `generic.xaml` dele
  (`packages/Microsoft.WindowsAppSDK.WinUI.1.8.*/lib/native/.../Themes/`)
  se os estados do `TabViewItem` leem as mesmas chaves. No WinUI 2.8,
  `TabViewItemHeaderBackground` só é lido nos estados selecionados.
  Verificar também se a releitura ainda precisa do truque do
  `RequestedTheme`. Os estilos que continuam em XAML embutido (botões
  `+`/`⌄` e itens do menu) seguem as regras do `XamlReader`: sem `x:Load`,
  sem `{StaticResource}` de fora do trecho.
- **Ícones:** `BitmapImage`/`SoftwareBitmapSource` existem iguais em
  `Microsoft::UI::Xaml::Media::Imaging`.
- **Brushes por árvore:** a regra de que um `Brush` pertence à árvore onde
  foi usado primeiro provavelmente continua. Manter os brushes por ilha.

### 5. Menu de perfis e popups

- **Objetivo:** abrir o menu como `MenuFlyout` da própria barra, sem a
  segunda ilha nem a janela estacionada fora da tela. Isso depende de os
  popups do WinUI 3 numa ilha poderem sair dos limites do HWND
  (`ShouldConstrainToRootBounds = false`). **Verificar** primeiro, com uma
  prova pequena no `poc3`.
- **Se não puder:** portar o esquema atual como está (segunda ilha numa
  janela de topo, `pretranslate` dela, pré-montagem).
- **Teclado do menu** (setas, Enter, Esc): continua igual, mudam só os
  tipos.

### 6. Interface que hoje é Win32 (fase B)

| Peça | Hoje | Em XAML |
|---|---|---|
| Paleta de comandos | `EDIT` + `LISTBOX` | `TextBox` + `ListView` filtrada, ou `AutoSuggestBox` |
| Busca no terminal | mesma `input_*` | `TextBox` com contador de resultados e setas |
| Renomear aba | mesma `input_*` | `TextBox` sobre a aba |
| Menus de contexto (aba e painel) | `TrackPopupMenu` | `MenuFlyout` |
| Rótulos do overview | janelas filhas GDI | Ficam: os quadros são GL, e XAML não pinta por cima de GL (ver *airspace*) |

A ABI `input_*`/`popup_menu` pode ficar como está; muda só o que a DLL
desenha por trás dela, então o Zig não precisa saber.

**Airspace:** conteúdo XAML não se desenha por cima da janela filha
OpenGL. Tudo o que hoje aparece *sobre* o terminal (paleta, busca, menus)
precisa ser janela própria: um popup em janela, se o item 5 confirmar que
existe, ou uma ilha numa janela de topo, como o menu de perfis.

### 7. Moldura e legenda (opcional)

Hoje os botões de legenda são XAML desenhados por nós, e a área de
arrastar é resolvida no `WM_NCHITTEST` do Zig. O Windows App SDK tem
`AppWindow`/`AppWindowTitleBar` e `InputNonClientPointerSource` para
declarar regiões de arrastar e de legenda. Isso pode apagar código nosso,
mas mexe no que já funciona (Snap Layouts no maximizar, duplo clique).
Fica para depois das fases A e B.

### 8. Notificações e barra de tarefas

- **Notificações:** `Windows.UI.Notifications` continua funcionando, com
  pacote e sem pacote (com o AppUserModelID `Ghostty.Terminal` do
  instalador). Não há motivo para trocar pelo `AppNotificationManager` do
  Windows App SDK agora.
- **Progresso:** `ITaskbarList3` não muda.

### 9. Distribuição

- **MSIX** (`AppxManifest.xml`): trocar as `PackageDependency` de
  `Microsoft.UI.Xaml.2.8` e `VCLibs` pela do Windows App Runtime 1.8
  (**verificar** o nome e a versão mínima exatos no `.nupkg`). O
  `package.ps1` e o `stage.ps1` deixam de tratar o WinUI 2.
- **setup.exe:**
  - `installer/stage.ps1` deixa de copiar `Microsoft.UI.Xaml.dll`, a pasta
    e o `resources.pri` do WinUI 2, e passa a copiar o
    `Microsoft.WindowsAppRuntime.Bootstrap.dll`;
  - `ghostty.iss` ganha a checagem e a instalação do runtime, no padrão do
    komorebi-switcher;
  - na opção self-contained, copiar os DLLs do runtime em vez disso.
- **Manifesto do exe:** o `dist/windows/ghostty.manifest` continua
  precisando de `maxversiontested`.
- **Notas do release:** dizer o que o usuário precisa (ou não) instalar.

### 10. Documentação

Atualizar `AGENTS.md` (passos de build), `dist/windows/tabbar/README.md`
(que descreve o WinUI 2 e o porquê dele) e este arquivo, marcando o que foi
feito.

## Riscos e o que verificar primeiro

Cada item é uma prova pequena, no `poc3` ou numa cópia dele, antes do
trabalho grande:

1. **Popups fora da ilha.** O `MenuFlyout` numa ilha do WinUI 3 pode
   passar dos limites do HWND? Define se o item 5 simplifica ou só porta.
2. **Pré-tradução de teclado.** Qual é a API do Windows App SDK 1.8 para
   o loop de mensagens de um host Win32 (aceleradores, Tab, setas na
   ilha)? Hoje isso passa por `ghostty_tabbar_pretranslate`.
3. **Duas janelas no mesmo processo.** Uma segunda ilha numa segunda
   janela de topo, com um `Application` por thread. Foi aqui que o WinUI 2
   derrubava o processo.
4. **Ilha baixa sobre GL.** Uma ilha da altura da faixa (~40 px), em cima
   de uma janela filha GL, redimensionando junto com a janela:
   composição, flicker no resize, DPI por monitor.
5. **Memória e abertura.** Medir com o mesmo método usado no WinUI 2
   (memória privada parada, tempo até a janela e até o prompt) e comparar.
   Hoje: ~60 MB privados parado; janela em 530–710 ms. Se o WinUI 3 piorar
   muito, isso pesa contra a migração.
6. **Bootstrap dentro da DLL.** O `ghostty_tabbar.dll` é dependência de
   carga do exe; garantir que nada do Windows App SDK é tocado antes do
   `ghostty_tabbar_init()`.

## Fases

| Fase | Entrega | Pronto quando |
|---|---|---|
| **0. Provas** | Os 6 itens de "Riscos" respondidos, cada um com o resultado anotado aqui | Decisões D1–D3 confirmadas ou revistas |
| **1. Build** | `fetch-deps.ps1` e `build.bat` gerando a DLL WinUI 3 a partir de uma checkout limpa, no CI também | O CI compila sem nada feito à mão |
| **2. Barra** | Faixa de abas, botões, menu de perfis, tema e ícones em WinUI 3, com a mesma ABI | Todos os testes de "Verificação" passam, com MSIX e com setup.exe |
| **3. Distribuição** | MSIX e setup.exe com o Windows App Runtime, notas de release | Instalar numa máquina sem o runtime funciona pelos dois caminhos |
| **4. Popups em XAML** | Paleta, busca, renomear e menus de contexto em XAML | Mesmos testes, com teclado completo nos popups |
| **5. Limpeza** | Remover WinUI 2, WebView2, `poc2`, a projeção antiga; atualizar READMEs e `AGENTS.md` | Nada no repositório referencia o WinUI 2 |

A fase 2 pode ir para release sozinha: a ABI não muda, então o resto do
port não percebe a troca.

## Verificação

O que testar a cada fase, nos dois modos de instalação:

- **Abertura:** a janela sobe já na cor do tema, sem painel apagado nem
  flash branco; a barra aparece de primeira.
- **Abas:** criar, fechar, selecionar, arrastar para reordenar, mover para
  outra janela, `move_tab`/`goto_tab` pelo teclado, título dinâmico.
- **Botões:** clique no `+` (perfil padrão) e no `⌄` (menu), com o efeito
  de pressionado; menu com teclado; Configurações e Paleta no menu; perfil
  como administrador.
- **Legenda:** minimizar, maximizar/restaurar (Snap Layouts no hover),
  fechar, overview; duplo clique e arrastar pela faixa.
- **Tema:** trocar o tema na config com o Ghostty aberto (o recarregamento
  ao vivo usado com o windots).
- **Segunda janela e terminal rápido** abrindo sem derrubar o processo;
  fechar janela sem travar.
- **Popups:** paleta (filtrar, setas, Enter, Esc), busca com contador,
  renomear, menus de contexto.
- **Notificação** (OSC 9) e **progresso** na barra de tarefas.
- **DPI:** arrastar a janela entre monitores com escalas diferentes.
- **Medidas:** memória privada parada, abertura até a janela e até o
  prompt, CPU parada, comparados com os números do WinUI 2 acima.
