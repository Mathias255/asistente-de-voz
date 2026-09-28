# Asistente de voz para Windows

Aplicacion de escritorio en espanol para conversar por voz o texto con un proveedor de IA compatible con la API de chat completions de OpenAI.

## Iniciar

1. En Windows, haz doble clic en `Iniciar Asistente.bat`.
2. Abre **Configuracion** e indica la URL del endpoint, el nombre del modelo y tu clave API.
3. Pulsa **Guardar**. Escribe una solicitud o pulsa **Iniciar microfono**. Con el envio automatico activado, el asistente envia lo reconocido cuando haces una pausa; desactivalo para revisar o editar el texto antes.
4. Activa **Leer respuestas en voz alta** para escuchar las respuestas.

La configuracion se guarda en `%APPDATA%\AsistenteVoz\settings.json`. La clave API se cifra con las protecciones de datos de Windows para el usuario actual. No se incluye ninguna clave en los archivos del proyecto.

## Requisitos y notas

- Windows con Windows PowerShell 5.1 y .NET Framework.
- Conexion al proveedor de IA que configures y una clave API valida.
- Para dictado, Windows debe tener instalado un motor de reconocimiento y un paquete de voz compatible. Se prefiere espanol; si no esta disponible, se usa otro motor instalado. El acceso al microfono puede requerir autorizacion en la configuracion de privacidad de Windows.
- La voz de salida usa las voces instaladas en Windows.
- Se aceptan proveedores con formato OpenAI Chat Completions. HTTPS es obligatorio salvo para servicios locales en loopback.

La conversacion se mantiene en memoria mientras la aplicacion esta abierta y se envia al endpoint configurado para generar respuestas. La clave no se envia a ningun otro destino.
