# talk-catcher

話し始めたら自動で録り、会話が終わったら録音ファイルを好きなコマンドに渡す Mac のメニューバーアプリ

- 声らしさ(Silero VAD)と音量の両方で flag を立て、声が1秒続いたら、3秒遡って録り始める
- flag が5分下がったら1本の会話として区切り、無音の末尾を切って m4a に保存する
- 保存したファイルを、設定に書いたコマンドに渡す。文字起こし・要約・転送など、その先はコマンドが決める
- flag が立つまで、音はメモリの30秒分だけで、ディスクにも外にも残らない

- 設計: `docs/design.html`
- 使ったときの体験の mock: `docs/mock.html`(ブラウザで開く)

## コマンドの例

コマンドには録音ファイルのパスが第1引数と `TC_FILE` で渡る。ほかに `TC_STARTED_AT`・`TC_ENDED_AT`・`TC_DURATION_SEC`・`TC_REASON` も渡る(詳しくは `docs/design.html`)。終了コード 0 で成功、それ以外は間を空けて再実行する

認証情報はアプリに書かず、コマンドの中で Keychain などから読む

文字起こし API に送る(OpenAI の場合):

```bash
curl -sf https://api.openai.com/v1/audio/transcriptions \
  -H "Authorization: Bearer $(security find-generic-password -s openai-api-key -w)" \
  -F model=gpt-4o-transcribe -F file=@"$TC_FILE" \
  > "${TC_FILE%.m4a}.json"
```

手元で文字起こしする(whisper.cpp の場合):

```bash
ffmpeg -loglevel error -i "$TC_FILE" -ar 16000 -ac 1 "${TC_FILE%.m4a}.wav" \
  && whisper-cli -m ~/models/ggml-large-v3-turbo.bin -l ja -otxt -f "${TC_FILE%.m4a}.wav"
```

## 録音について

周りの人の声も録れる。相手の同意や職場のルールは、使う人が確かめること

## ライセンス

MIT(`LICENSE`)。同梱している Silero VAD と ONNX Runtime の表示は `THIRD_PARTY_NOTICES.md` にある
