Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Speech

$ErrorActionPreference = 'Stop'
$configDirectory = Join-Path $env:APPDATA 'AsistenteVoz'
$configPath = Join-Path $configDirectory 'settings.json'
$script:settings = [ordered]@{
    Endpoint = 'https://api.openai.com/v1/chat/completions'
    Model = 'gpt-4o-mini'
    ProtectedKey = ''
}
$script:conversation = New-Object System.Collections.ArrayList
$script:speechQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:speechCompletionQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[bool]'
$script:recognizer = $null
$script:speechSubscription = $null
$script:speechCompletionSubscription = $null
$script:requestJob = $null
$script:isListening = $false
$script:isSpeaking = $true
$script:autoSendVoice = $true
$script:lastSpeechAt = $null
$script:resumeListeningAfterSpeech = $false
$script:isResponseSpeechActive = $false
$script:pendingSpeechCount = 0
$script:synthesizer = $null

if (Test-Path -LiteralPath $configPath) {
    try {
        $savedSettings = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        if ($savedSettings.Endpoint) { $script:settings.Endpoint = [string]$savedSettings.Endpoint }
        if ($savedSettings.Model) { $script:settings.Model = [string]$savedSettings.Model }
        if ($savedSettings.ProtectedKey) { $script:settings.ProtectedKey = [string]$savedSettings.ProtectedKey }
    }
    catch {
        [System.Windows.MessageBox]::Show(
            "No se pudo leer la configuracion guardada. Abre Configuracion para corregirla.`n`n$($_.Exception.Message)",
            'Asistente de voz',
            'OK',
            'Warning'
        ) | Out-Null
    }
}

[xml]$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Asistente de voz" Height="720" Width="920" MinHeight="560" MinWidth="680"
        WindowStartupLocation="CenterScreen" Background="#F4F6FA" FontFamily="Segoe UI">
  <DockPanel>
    <Border DockPanel.Dock="Top" Background="#172554" Padding="22,16">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel>
          <TextBlock Text="Asistente de voz" Foreground="White" FontSize="23" FontWeight="SemiBold"/>
          <TextBlock Text="Habla o escribe para empezar" Foreground="#BFDBFE" FontSize="13" Margin="0,3,0,0"/>
        </StackPanel>
        <Button x:Name="SettingsButton" Grid.Column="1" Content="Configuracion"
                Padding="14,9" VerticalAlignment="Center" Background="#263B69"
                Foreground="White" BorderBrush="#52658E" Cursor="Hand"/>
      </Grid>
    </Border>
    <Border DockPanel.Dock="Bottom" Background="White" BorderBrush="#E2E8F0" BorderThickness="0,1,0,0" Padding="18,12">
      <StackPanel Orientation="Horizontal">
        <Ellipse x:Name="StatusDot" Width="9" Height="9" Fill="#94A3B8" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <TextBlock x:Name="StatusText" Text="Listo" Foreground="#475569" VerticalAlignment="Center"/>
      </StackPanel>
    </Border>
    <Grid Margin="22,18,22,16">
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Border Grid.Row="0" Background="White" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="10" Padding="18" Margin="0,0,0,14">
        <TextBox x:Name="ChatBox" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                 BorderThickness="0" Background="Transparent" FontSize="14" Foreground="#1E293B"/>
      </Border>
      <Grid Grid.Row="1" Margin="0,0,0,12">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBox x:Name="InputBox" Grid.Column="0" Height="52" FontSize="15" Padding="12"
                 VerticalContentAlignment="Center" AcceptsReturn="False"
                 ToolTip="Escribe tu mensaje y pulsa Enviar"/>
        <Button x:Name="SendButton" Grid.Column="1" Content="Enviar" Margin="10,0,0,0" MinWidth="100"
                Background="#2563EB" Foreground="White" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand"/>
      </Grid>
      <StackPanel Grid.Row="2" Orientation="Horizontal">
        <Button x:Name="MicButton" Content="Iniciar microfono" Padding="14,8" Margin="0,0,10,0"
                Background="White" BorderBrush="#CBD5E1" Cursor="Hand"/>
        <CheckBox x:Name="SpeakCheckBox" Content="Leer respuestas en voz alta" IsChecked="True"
                  VerticalAlignment="Center" Foreground="#475569"/>
        <CheckBox x:Name="AutoSendCheckBox" Content="Enviar voz automaticamente" IsChecked="True"
                  VerticalAlignment="Center" Foreground="#475569" Margin="18,0,0,0"/>
      </StackPanel>
    </Grid>
  </DockPanel>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $mainXaml))
$chatBox = $window.FindName('ChatBox')
$inputBox = $window.FindName('InputBox')
$sendButton = $window.FindName('SendButton')
$micButton = $window.FindName('MicButton')
$statusText = $window.FindName('StatusText')
$statusDot = $window.FindName('StatusDot')
$speakCheckBox = $window.FindName('SpeakCheckBox')
$autoSendCheckBox = $window.FindName('AutoSendCheckBox')

function Set-Status {
    param([string]$Text, [string]$Color = '#94A3B8')
    $statusText.Text = $Text
    $statusDot.Fill = [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function Add-ChatLine {
    param([string]$Speaker, [string]$Text)
    $chatBox.AppendText("$Speaker`r`n$Text`r`n`r`n")
    $chatBox.ScrollToEnd()
}

function Get-ApiKey {
    if ([string]::IsNullOrWhiteSpace($script:settings.ProtectedKey)) { return '' }
    $secureKey = ConvertTo-SecureString -String $script:settings.ProtectedKey
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Show-Settings {
    [xml]$settingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Configuracion" Height="390" Width="540" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" Background="#F8FAFC" FontFamily="Segoe UI">
  <Grid Margin="24">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="Proveedor de IA compatible con OpenAI" FontSize="19" FontWeight="SemiBold" Foreground="#172554" Margin="0,0,0,18"/>
    <StackPanel Grid.Row="1" Margin="0,0,0,12">
      <TextBlock Text="URL del endpoint de chat completions" Foreground="#334155" Margin="0,0,0,5"/>
      <TextBox x:Name="EndpointBox" Height="34" Padding="8"/>
    </StackPanel>
    <StackPanel Grid.Row="2" Margin="0,0,0,12">
      <TextBlock Text="Modelo" Foreground="#334155" Margin="0,0,0,5"/>
      <TextBox x:Name="ModelBox" Height="34" Padding="8"/>
    </StackPanel>
    <StackPanel Grid.Row="3" Margin="0,0,0,10">
      <TextBlock Text="Clave API" Foreground="#334155" Margin="0,0,0,5"/>
      <PasswordBox x:Name="KeyBox" Height="34" Padding="8"/>
    </StackPanel>
    <TextBlock Grid.Row="4" Text="La clave se guarda cifrada para tu usuario de Windows. Se permite HTTP solo para direcciones locales."
               Foreground="#64748B" TextWrapping="Wrap" FontSize="12" VerticalAlignment="Top" Margin="0,2,0,10"/>
    <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="CancelButton" Content="Cancelar" Padding="16,8" Margin="0,0,8,0"/>
      <Button x:Name="SaveButton" Content="Guardar" Padding="16,8" Background="#2563EB" Foreground="White" BorderThickness="0"/>
    </StackPanel>
  </Grid>
</Window>
'@
    $dialog = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $settingsXaml))
    $dialog.Owner = $window
    $endpointBox = $dialog.FindName('EndpointBox')
    $modelBox = $dialog.FindName('ModelBox')
    $keyBox = $dialog.FindName('KeyBox')
    $endpointBox.Text = $script:settings.Endpoint
    $modelBox.Text = $script:settings.Model
    $keyBox.Password = Get-ApiKey

    $dialog.FindName('CancelButton').Add_Click({ $dialog.DialogResult = $false })
    $dialog.FindName('SaveButton').Add_Click({
        $endpointUri = $null
        if (-not [Uri]::TryCreate($endpointBox.Text.Trim(), [UriKind]::Absolute, [ref]$endpointUri) -or
            $endpointUri.Scheme -notin @('https', 'http')) {
            [System.Windows.MessageBox]::Show('Introduce una URL valida con esquema HTTPS.', 'Configuracion', 'OK', 'Warning') | Out-Null
            return
        }
        if ($endpointUri.Scheme -eq 'http' -and -not $endpointUri.IsLoopback) {
            [System.Windows.MessageBox]::Show('Por seguridad, HTTP solo se permite en localhost. Usa HTTPS para otros servidores.', 'Configuracion', 'OK', 'Warning') | Out-Null
            return
        }
        if ([string]::IsNullOrWhiteSpace($modelBox.Text)) {
            [System.Windows.MessageBox]::Show('El nombre del modelo no puede estar vacio.', 'Configuracion', 'OK', 'Warning') | Out-Null
            return
        }

        try {
            if (-not (Test-Path -LiteralPath $configDirectory)) {
                New-Item -Path $configDirectory -ItemType Directory -Force | Out-Null
            }
            $secureKey = $keyBox.SecurePassword
            $protectedKey = if ($secureKey.Length -gt 0) { ConvertFrom-SecureString -SecureString $secureKey } else { '' }
            $newSettings = [ordered]@{
                Endpoint = $endpointUri.AbsoluteUri
                Model = $modelBox.Text.Trim()
                ProtectedKey = $protectedKey
            }
            $newSettings | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
            $script:settings = $newSettings
            $dialog.DialogResult = $true
        }
        catch {
            [System.Windows.MessageBox]::Show("No se pudo guardar la configuracion.`n`n$($_.Exception.Message)", 'Configuracion', 'OK', 'Error') | Out-Null
        }
    })
    $null = $dialog.ShowDialog()
}

function Stop-Listening {
    $cleanupErrors = @()
    if ($script:recognizer) {
        try {
            if ($script:isListening) { $script:recognizer.RecognizeAsyncCancel() }
        }
        catch {
            $cleanupErrors += "No se pudo cancelar el reconocimiento: $($_.Exception.Message)"
        }
        try {
            $script:recognizer.Dispose()
        }
        catch {
            $cleanupErrors += "No se pudo liberar el motor de reconocimiento: $($_.Exception.Message)"
        }
        $script:recognizer = $null
    }
    if ($script:speechSubscription) {
        try {
            Unregister-Event -SubscriptionId $script:speechSubscription.Id
            Remove-Job -Id $script:speechSubscription.Id -Force
        }
        catch {
            $cleanupErrors += "No se pudo cerrar la suscripcion de voz: $($_.Exception.Message)"
        }
        $script:speechSubscription = $null
    }
    $script:isListening = $false
    $micButton.Content = 'Iniciar microfono'
    if ($cleanupErrors.Count -gt 0) {
        Add-ChatLine 'Aviso' ($cleanupErrors -join "`r`n")
        Set-Status 'Error al detener el microfono' '#DC2626'
    }
}

function Start-Listening {
    try {
        $recognizers = [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers()
        if ($null -eq $recognizers -or $recognizers.Count -eq 0) {
            throw 'Windows no tiene un motor de reconocimiento instalado. Instala el paquete de voz de espanol desde Configuracion > Hora e idioma > Voz.'
        }
        $recognizerInfo = $recognizers | Where-Object { $_.Culture.Name -eq 'es-ES' } | Select-Object -First 1
        if ($null -eq $recognizerInfo) {
            $recognizerInfo = $recognizers | Where-Object { $_.Culture.TwoLetterISOLanguageName -eq 'es' } | Select-Object -First 1
        }
        if ($null -eq $recognizerInfo) { $recognizerInfo = $recognizers | Select-Object -First 1 }

        $script:recognizer = New-Object System.Speech.Recognition.SpeechRecognitionEngine($recognizerInfo)
        $script:recognizer.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
        $script:recognizer.SetInputToDefaultAudioDevice()
        $discarded = $null
        while ($script:speechQueue.TryDequeue([ref]$discarded)) { }
        $script:speechSubscription = Register-ObjectEvent -InputObject $script:recognizer -EventName SpeechRecognized -MessageData $script:speechQueue -Action {
            $recognizedText = $Event.SourceEventArgs.Result.Text
            if (-not [string]::IsNullOrWhiteSpace($recognizedText)) {
                $Event.MessageData.Enqueue($recognizedText)
            }
        }
        $script:recognizer.RecognizeAsync([System.Speech.Recognition.RecognizeMode]::Multiple)
        $script:isListening = $true
        $micButton.Content = 'Detener microfono'
        Set-Status "Escuchando ($($recognizerInfo.Culture.Name))" '#16A34A'
    }
    catch {
        Stop-Listening
        Set-Status 'Microfono no disponible' '#DC2626'
        [System.Windows.MessageBox]::Show("No se pudo iniciar el reconocimiento de voz.`n`n$($_.Exception.Message)", 'Microfono', 'OK', 'Warning') | Out-Null
    }
}

function Speak-Response {
    param([string]$Text)
    $script:resumeListeningAfterSpeech = $script:resumeListeningAfterSpeech -or $script:isListening
    if ($script:isListening) { Stop-Listening }
    $script:isResponseSpeechActive = $true
    $micButton.Content = 'Microfono pausado'
    $micButton.IsEnabled = $false

    try {
        if (-not $script:synthesizer) {
            $script:synthesizer = New-Object System.Speech.Synthesis.SpeechSynthesizer
        }
        if (-not $script:speechCompletionSubscription) {
            $script:speechCompletionSubscription = Register-ObjectEvent -InputObject $script:synthesizer `
                -EventName SpeakCompleted -MessageData $script:speechCompletionQueue -Action {
                    $Event.MessageData.Enqueue($true)
                }
        }
        $script:pendingSpeechCount++
        $script:synthesizer.SpeakAsync($Text) | Out-Null
    }
    catch {
        if ($script:pendingSpeechCount -gt 0) { $script:pendingSpeechCount-- }
        if ($script:pendingSpeechCount -eq 0) {
            $script:isResponseSpeechActive = $false
            $micButton.IsEnabled = $true
            if ($script:resumeListeningAfterSpeech) {
                $script:resumeListeningAfterSpeech = $false
                Start-Listening
            }
        }
        Add-ChatLine 'Aviso' "No se pudo reproducir la respuesta en voz alta: $($_.Exception.Message)"
    }
}

function Send-Message {
    param([string]$Text)
    $message = $Text.Trim()
    if ([string]::IsNullOrWhiteSpace($message) -or $script:requestJob) { return }
    $apiKey = Get-ApiKey
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        [System.Windows.MessageBox]::Show('Configura tu clave API antes de enviar un mensaje.', 'Falta configuracion', 'OK', 'Information') | Out-Null
        Show-Settings
        return
    }

    $inputBox.Clear()
    Add-ChatLine 'Tu' $message
    [void]$script:conversation.Add(@{ role = 'user'; content = $message })
    $history = @($script:conversation | Select-Object -Last 20)
    $systemMessage = @{ role = 'system'; content = 'Eres un asistente de voz útil y versátil. Responde en español de forma clara y natural, salvo que el usuario pida otro idioma. Ayuda con preguntas, explicaciones, redacción, traducción, ideas, planificación y tareas generales. Si falta información importante, pregunta antes de asumir.' }
    $messagesJson = ConvertTo-Json -InputObject (@($systemMessage) + $history) -Depth 8 -Compress
    $endpoint = $script:settings.Endpoint
    $model = $script:settings.Model

    $sendButton.IsEnabled = $false
    $inputBox.IsEnabled = $false
    Set-Status 'Pensando...' '#2563EB'
    $script:requestJob = Start-Job -ArgumentList $endpoint, $model, $apiKey, $messagesJson -ScriptBlock {
        param($RequestEndpoint, $RequestModel, $RequestKey, $RequestMessagesJson)
        try {
            $chatMessages = ConvertFrom-Json -InputObject $RequestMessagesJson
            $payload = @{ model = $RequestModel; messages = @($chatMessages); temperature = 0.7 } | ConvertTo-Json -Depth 10
            $response = Invoke-RestMethod -Uri $RequestEndpoint -Method Post -ContentType 'application/json; charset=utf-8' `
                -Headers @{ Authorization = "Bearer $RequestKey" } -Body $payload -TimeoutSec 120
            $answer = [string]$response.choices[0].message.content
            if ([string]::IsNullOrWhiteSpace($answer)) { throw 'El proveedor devolvio una respuesta vacia o con formato no compatible.' }
            @{ Success = $true; Answer = $answer; Error = '' } | ConvertTo-Json -Compress
        }
        catch {
            $caughtError = $_
            $errorMessage = $caughtError.Exception.Message
            $responseBody = [string]$caughtError.ErrorDetails.Message
            $response = $caughtError.Exception.Response
            if ($response) {
                $statusCode = [int]$response.StatusCode
                try {
                    if ([string]::IsNullOrWhiteSpace($responseBody)) {
                        $responseStream = $response.GetResponseStream()
                        if ($responseStream) {
                            $reader = New-Object System.IO.StreamReader($responseStream)
                            try {
                                $responseBody = $reader.ReadToEnd()
                            }
                            finally {
                                $reader.Dispose()
                            }
                        }
                    }
                }
                catch {
                    $errorMessage += " No se pudo leer el detalle HTTP: $($_.Exception.Message)"
                }

                if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
                    try {
                        $errorBody = ConvertFrom-Json -InputObject $responseBody -ErrorAction Stop
                        if ($errorBody.error.message) {
                            $errorMessage = [string]$errorBody.error.message
                            if ($errorBody.error.type) { $errorMessage += " (tipo: $($errorBody.error.type))" }
                            if ($errorBody.error.code) { $errorMessage += " (codigo: $($errorBody.error.code))" }
                        }
                        else {
                            $errorMessage = $responseBody
                        }
                    }
                    catch {
                        $errorMessage = $responseBody
                    }
                }

                if ($statusCode -eq 429) {
                    $errorMessage = "Error HTTP 429 (limite o cuota de API). $errorMessage"
                    if ($errorMessage -match '(?i)insufficient_quota|quota|billing|credit') {
                        $errorMessage += ' Revisa la facturacion, el saldo y los limites del proyecto de API.'
                    }
                    else {
                        $retryAfter = $response.Headers['Retry-After']
                        if ($retryAfter) {
                            $errorMessage += " Reintenta en $retryAfter segundos."
                        }
                        else {
                            $errorMessage += ' Si ocurre con cada mensaje, revisa la facturacion y los limites del proyecto; esperar no solucionara una cuota agotada.'
                        }
                    }
                }
            }
            elseif ($caughtError.ErrorDetails.Message) {
                $errorMessage = [string]$caughtError.ErrorDetails.Message
            }
            @{ Success = $false; Answer = ''; Error = $errorMessage } | ConvertTo-Json -Compress
        }
    }
}

$window.FindName('SettingsButton').Add_Click({ Show-Settings })
$sendButton.Add_Click({ Send-Message $inputBox.Text })
$inputBox.Add_KeyDown({
    if ($_.Key -eq [System.Windows.Input.Key]::Enter) {
        Send-Message $inputBox.Text
        $_.Handled = $true
    }
})
$micButton.Add_Click({
    if ($script:isListening) { Stop-Listening; Set-Status 'Microfono detenido' }
    else { Start-Listening }
})
$speakCheckBox.Add_Checked({ $script:isSpeaking = $true })
$speakCheckBox.Add_Unchecked({ $script:isSpeaking = $false })
$autoSendCheckBox.Add_Checked({ $script:autoSendVoice = $true })
$autoSendCheckBox.Add_Unchecked({ $script:autoSendVoice = $false })

$uiTimer = New-Object System.Windows.Threading.DispatcherTimer
$uiTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$uiTimer.Add_Tick({
    $recognizedText = $null
    while ($script:speechQueue.TryDequeue([ref]$recognizedText)) {
        $inputBox.Text = if ([string]::IsNullOrWhiteSpace($inputBox.Text)) { $recognizedText } else { "$($inputBox.Text) $recognizedText" }
        $inputBox.CaretIndex = $inputBox.Text.Length
        $inputBox.Focus()
        $script:lastSpeechAt = [DateTime]::UtcNow
    }

    $completedUtterance = $false
    $speechCompleted = $false
    while ($script:speechCompletionQueue.TryDequeue([ref]$speechCompleted)) {
        $completedUtterance = $true
        if ($script:pendingSpeechCount -gt 0) { $script:pendingSpeechCount-- }
    }
    if ($completedUtterance -and $script:pendingSpeechCount -eq 0 -and $script:isResponseSpeechActive -and
        $script:synthesizer.State -eq [System.Speech.Synthesis.SynthesizerState]::Ready) {
        $script:isResponseSpeechActive = $false
        $micButton.IsEnabled = $true
        if ($script:resumeListeningAfterSpeech) {
            $script:resumeListeningAfterSpeech = $false
            Start-Listening
        }
    }

    if ($script:autoSendVoice -and $script:lastSpeechAt -and
        ([DateTime]::UtcNow - $script:lastSpeechAt).TotalMilliseconds -ge 1200) {
        if (-not $script:requestJob -and -not [string]::IsNullOrWhiteSpace($inputBox.Text)) {
            $script:lastSpeechAt = $null
            Send-Message $inputBox.Text
        }
        elseif ([string]::IsNullOrWhiteSpace($inputBox.Text)) {
            $script:lastSpeechAt = $null
        }
    }

    if ($script:requestJob -and $script:requestJob.State -in @('Completed', 'Failed', 'Stopped')) {
        $job = $script:requestJob
        $script:requestJob = $null
        $sendButton.IsEnabled = $true
        $inputBox.IsEnabled = $true
        try {
            $jobOutput = Receive-Job -Job $job -ErrorAction Stop
            Remove-Job -Job $job -Force
            if (-not $jobOutput) { throw 'El proveedor no devolvio una respuesta.' }
            $resultJson = $jobOutput | Select-Object -Last 1
            $result = [string]$resultJson | ConvertFrom-Json
            if (-not $result.Success) { throw [string]$result.Error }
            [void]$script:conversation.Add(@{ role = 'assistant'; content = [string]$result.Answer })
            Add-ChatLine 'Asistente' ([string]$result.Answer)
            Set-Status 'Listo' '#16A34A'
            if ($script:isSpeaking) {
                Speak-Response ([string]$result.Answer)
            }
        }
        catch {
            Add-ChatLine 'Aviso' "No se pudo completar la solicitud: $($_.Exception.Message)"
            Set-Status 'Error en la solicitud' '#DC2626'
        }
    }
})
$uiTimer.Start()

Add-ChatLine 'Asistente' 'Hola. Puedo ayudarte con preguntas, ideas, redaccion, traducciones, planificacion y otras tareas. Configura un proveedor de IA y habla o escribe tu solicitud.'
$window.Add_Closed({
    $uiTimer.Stop()
    Stop-Listening
    if ($script:requestJob) {
        Stop-Job -Job $script:requestJob
        Remove-Job -Job $script:requestJob -Force
    }
    if ($script:speechCompletionSubscription) {
        Unregister-Event -SubscriptionId $script:speechCompletionSubscription.Id
        Remove-Job -Id $script:speechCompletionSubscription.Id -Force
    }
    if ($script:synthesizer) { $script:synthesizer.Dispose() }
})
$null = $window.ShowDialog()
