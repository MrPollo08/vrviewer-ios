# VR Viewer — port a iOS

Port nativo a **iOS / iPhone** de [`adrianortizvcv32/vrviewerapk`](https://github.com/adrianortizvcv32/vrviewerapk)
(visores VR que usan el iPhone como HMD + manos para SteamVR).

El protocolo binario con el PC es **idéntico byte a byte** al del Android, así que
el driver C++ de SteamVR no necesita ningún cambio.

---

## 1. Cómo obtener el `.ipa` (sin Mac)

Compilar un `.ipa` requiere el SDK de iOS, que solo existe en macOS. La solución
es GitHub Actions: un runner macOS compila y publica el archivo.

1. Crea un repositorio en GitHub (puede ser privado) y sube **el contenido de
   esta carpeta** (no la carpeta en sí): `project.yml`, `VRViewer/`, `Support/`,
   `.github/`.

   ```bash
   cd VRViewer-iOS
   git init
   git add .
   git commit -m "VR Viewer iOS"
   git branch -M main
   git remote add origin https://github.com/TU_USUARIO/vrviewer-ios.git
   git push -u origin main
   ```

2. Entra en **Actions → Build IPA → Run workflow** (o simplemente espera: también
   se dispara en cada push). Tarda ~5–10 minutos.

3. Cuando termine, abre el run y descarga el artifact **`VRViewer-ipa`**.
   Dentro está `VRViewer.ipa`.

> El `.ipa` sale **sin firmar** (no se puede firmar sin tu cuenta de Apple).
> Eso es lo normal para instalar con Sideloadly / AltStore.

### Instalarlo en el iPhone

| Herramienta | Coste | Duración | Notas |
|---|---|---|---|
| **Sideloadly** (recomendado) | gratis | 7 días | Firma con tu Apple ID normal desde Windows/Mac |
| **AltStore / SideStore** | gratis | 7 días | Renueva sola en segundo plano |
| Cuenta de desarrollador (99 €/año) | pago | 1 año | Sin límite de 3 apps |

Pasos con Sideloadly (Windows):

1. Instala Sideloadly y iTunes (o Apple Devices).
2. Conecta el iPhone, arrastra `VRViewer.ipa` a Sideloadly, pon tu Apple ID.
3. En el iPhone: **Ajustes → General → VPN y gestión de dispositivos** →
   confía en tu certificado.
4. En iOS 16+ hay que activar **Modo de desarrollador** (Ajustes → Privacidad y
   seguridad → Modo de desarrollador) y reiniciar.

---

## 2. Qué se ha portado

| Función del Android | En iOS | Estado |
|---|---|---|
| Handshake HMAC-SHA256 (UDP 47292) | CryptoKit | ✅ idéntico |
| Tracking 196 bytes a 90 Hz (UDP 47291) | BSD sockets | ✅ idéntico |
| Comando `RECN` del PC (UDP 47293) | BSD sockets | ✅ |
| Autodescubrimiento `CVRANNOUNCE` (UDP 47294) | BSD sockets | ✅ |
| Stream H.264 por TCP 47295 | VideoToolbox vía `AVSampleBufferDisplayLayer` | ✅ |
| Audio PCM 48 kHz TCP 47298 | AVAudioEngine | ✅ |
| Giroscopio → HMD | CoreMotion (misma matemática) | ✅ |
| Manos (MediaPipe) | **Vision** (`VNDetectHumanHandPoseRequest`) | ✅ 21 puntos, mismos gestos |
| Pinch / grip / curl por dedo | port literal de las fórmulas | ✅ |
| Suavizado One Euro + slerp + recentrado | port literal | ✅ |
| 6DoF (ARCore) | **ARKit** | ✅ |
| Calidad de stream (UDP 47296 `QUAL`) | igual | ✅ |
| Panel de lentes (separación / lupa) | CALayer transform | ✅ + altura |
| Joy-Con por HID | — | ❌ iOS no expone HID de Nintendo |
| Cable USB/ADB (`adb reverse`) | — | ❌ no existe en iOS (sí vale el *tethering* USB) |
| Menú Hub / navegador 3D | — | ❌ no portado |
| Video SBS local | — | ❌ no portado |
| Eye tracking OSC | — | ❌ requiere TrueDepth + no portado |
| Distorsión de barril del shader | — | ⚠️ no incluida (ver abajo) |

### Notas honestas

- **Distorsión de barril**: el original usa un shader OpenGL que deforma cada
  ojo para compensar las lentes. Aquí el video lo decodifica
  `AVSampleBufferDisplayLayer` (zero-copy, latencia mínima) y solo se aplican
  desplazamiento/zoom. Para tener la deformación exacta hay que decodificar a
  textura con VideoToolbox + Metal; se puede añadir como v2 sin tocar nada más.
- **Manos sin profundidad**: Vision da 21 puntos 2D; MediaPipe daba `z`. Los
  gestos (pinch, grip, curl) usan las mismas fórmulas normalizadas y funcionan,
  pero la profundidad de la mano se estima por el tamaño aparente, como el
  propio original ya hacía para `vz`.
- **Manos + 6DoF**: comparten la cámara. Con 6DoF activo las manos se detectan
  sobre los frames de ARKit, igual que el original hacía con ARCore.

---

## 3. Uso

1. En el PC: SteamVR + driver C++ + `ffmpeg` enviando el stream, como siempre.
2. En la app: pestaña **WiFi**, espera a que aparezca tu PC (o escribe la IP a
   mano) y pulsa **Conectar**.
3. En el panel de control activa lo que uses: **Giroscopio**, **Manos**,
   **6DoF**.
4. **▶ Abrir stream** para ver SteamVR en el visor.

Dentro del stream, toca la pantalla para mostrar/ocultar los controles:

- **⚙ Calidad**: resolución, bitrate y FPS (se piden al PC por UDP 47296).
- **🔍 Lentes**: separación entre ojos, lupa y altura.
- **⟳ Recentrar**: pone la orientación actual como "adelante".
- **✕ Cerrar**: vuelve al panel (el tracking sigue activo).

Si las manos salen cruzadas o giradas, en el panel de control tienes
**Invertir manos** y **Rotación de cámara** (0/90/180/270°).

---

## 4. Compilar con Mac (alternativa)

```bash
brew install xcodegen
xcodegen generate
open VRViewer.xcodeproj
```

Selecciona tu equipo en *Signing & Capabilities*, conecta el iPhone y ejecuta.
El bundle id por defecto es `com.vrviewer.ios` (cámbialo si te da conflicto).

---

## 5. Estructura

```
project.yml                  proyecto XcodeGen (genera VRViewer.xcodeproj)
Support/Info.plist           permisos (cámara, red local, movimiento), landscape
VRViewer/
  App/VRViewerApp.swift      entry point
  App/AppState.swift         orquestador (conexión, tracking, video, audio)
  Core/VRPackets.swift       layout exacto del paquete de 196 bytes + QUAL
  Core/VRLink.swift          auth HMAC + envío 90 Hz + comandos
  Core/Sockets.swift         UDP/TCP sobre BSD sockets
  Core/PCDiscovery.swift     autodescubrimiento
  Core/Models.swift          HandPose / Quat / HeadPose6DoF
  Core/VRMath.swift          quaterniones, matrices, One Euro
  Motion/HeadMotion.swift    CoreMotion → cuaternión del HMD
  Motion/HandProcessor.swift Vision: 21 puntos → HandPose
  Motion/HandGestures.swift  pinch/grip/curl + suavizado + recentrado
  Motion/HandCamera.swift    cámara trasera para manos
  Motion/SixDoF.swift        ARKit
  Video/H264Assembler.swift  NALs → CMSampleBuffer
  Video/StreamClient.swift   TCP 47295
  Video/StereoVideoView.swift dos ojos (SBS) + separación/lupa
  Audio/AudioClient.swift    TCP 47298 + AVAudioEngine
  UI/…                       pantallas SwiftUI
.github/workflows/build-ipa.yml
```

---

## 6. Problemas típicos

| Síntoma | Causa / solución |
|---|---|
| "La PC no respondió (timeout)" | Firewall de Windows bloqueando UDP 47292, o IP equivocada |
| Conecta pero no aparece la PC en la lista | El PC no está anunciando en UDP 47294; escribe la IP a mano |
| Pantalla negra en el stream | El PC no está mandando SPS/PPS (reconecta el stream) o el firewall bloquea TCP 47295 |
| No hay audio | Firewall TCP 47298 |
| Las manos no se detectan | Falta permiso de cámara, o poca luz |
| 6DoF "sin señal" | Superficie sin textura / poca luz (igual que ARCore) |
| Se cae a los 7 días | Firma gratuita de Apple: vuelve a firmar con Sideloadly |

---

## 7. Licencia

El proyecto original incluye su propia licencia; este port mantiene el mismo
espíritu. El código aquí es nuevo (Swift), escrito a partir del comportamiento
del original.
