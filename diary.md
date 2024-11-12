# 1️⃣ 環境構築

下記のリポジトリで説明されている OrbStack の場合で実験してみる。
https://github.com/matsuu/cloud-init-isucon

## cloud-init とは

元々はクラウドで仮想マシンを立ち上げた時に、環境設定を自動化するためのツールらしい。ユーザ追加、ssh設定、環境変数設定と言ったことができるらしい。Ubuntu の開発会社が作ったのが始まりで今では AWS とか GCP とかのプラットフォームもサポートしているとのこと。cloud-init は設定ファイル一個でほぼやりたいことを記述する。例えば下のような感じ。

```
#cloud-config
package_update: true
packages:
  - nginx
runcmd:
  - echo "Hello, Cloud-Init!" > /var/www/html/index.html
  - systemctl restart nginx
```

この設定ファイルには、仮想マシンが起動した後にやるべきことが書いてある。あとは、これをクラウドプラットフォームの設定画面で渡してあげるだけで良い。今回は AWS とかは使わないで localhost に仮想マシンを起動して cloud-init の設定ファイルを渡す。下記のコマンドで cfg が cloud-init の設定ファイルになっている。

```
orbctl create -u isucon -c isucon13/isucon13.cfg ubuntu:jammy isucon13
```

もちろん ansible とか他のツールでも実行できるけど、最初の一回だけやる、VM 起動時にやる、ということをコンパクトにまとめている点で cloud-init の利点はあると思う。

## orb / orbclt とは

OrbStack は docker コマンドを使うためのプラットフォームとして使うのがシンプルだけど Linux の VM のプラットフォームとしても使える。用途が限られた Virtual Box みたいな感じ。この機能を使う時には orb または orbctl というコマンドを使う。どちらもほぼ同じだが orb の場合はより強力なショートカットを持っている。混乱がないように orbctl を使ってもいい。今回の isucon では下記のコマンドで VM を作成している。

```
orbctl create -u isucon -c isucon13/isucon13.cfg ubuntu:jammy isucon13
```

- -u isucon はユーザ名
- -c isucon13/isucon13.cfg は cloud-init の設定ファイル指定
- ubuntu:jammy は linux ディストリビューションとバージョン指定
- isucon13 はマシン名

起動中の VM に ssh するには下記のコマンドを実行する。

```
ssh orb
```

## isucon13.cfg の中身

cloud-init の実行を待っている間に、少し中身を見てみる。

https://github.com/matsuu/cloud-init-isucon/blob/main/isucon13/isucon13.cfg

パッケージのインストールをしたあと、github からソースコードを取得、証明書の設定などをやっている。それから make コマンドで環境構築しているようだ。このあたりでフロントエンドのビルドや、ベンチマーク用のコマンドをビルドしたりなんだりしているらしい。下記に相当することをやっているようだ。

https://github.com/isucon/isucon13/blob/main/provisioning/ansible/make_latest_files.sh

フロントエンドでは vite を使ってるらしい。これが走り切ったら、おそらくUbuntu1台のみで動く構成となる。40分ほどかかって完了した。
初回ベンチマークと動作確認 - 12094
まずベンチマークを実行して初期データを作成する。

ssh orb
./bench run --enable-ssl

初期スコアは 12094 点。ホスト OS の /etc/hosts に下記を追加した。

127.0.0.1 pipe.u.isucon.local

その後 https://pipe.u.isucon.local/ を開いた。マニュアルに書いてあるとおり、アカウント test001/test を使ってログインできた。

# 2️⃣ マニュアル読み込み & インフラ構成の確認
isupipe のコードを github 上にアップロードした。nginx の設定を眺めて、シングルページアプリケーションになってることを確認した。[当日マニュアル](https://github.com/isucon/isucon13/blob/main/docs/cautionary_note.md)を読みながら ruby に取り替える。

```
sudo systemctl disable --now isupipe-go.service
sudo systemctl enable --now isupipe-ruby.service
```

## DNS の動作確認

DNS の動作を確認してみよう。まず下記の dig で確認してみた。status: refused が帰ってくる。なんかがおかしいかも。


```
sudo apt install dnsutils
dig pipe.u.isucon.dev @127.0.0.1
```

pdns のプロセスの様子を確認してみるが、問題はなさそうだ。

```
systemctl status pdns
pdnsutil list-all-zones
> u.isucon.local
```

内部的に mysql が動いているようだ。下記にpowerDNS の mysql 接続設定が書いてあった。

```
cat /etc/powerdns/pdns.conf
```

これに従うとこうなる。ホスト指定とかはない。

```
mysql -u isudns -pisudns -P3306 isudns
select * from records;
```

問題はなさそうだ。record の中に含まれてるドメインで dig を行う。

```
dig isato4.u.isucon.local @127.0.0.1
```

今度は status: noerror となった。どうやら実験に使った `pipe.u.isucon.dev` というのが records に登録されてないので名前解決できなかったらしい。とりあえず power DNS は問題なさそう。

## MySQL の動作確認

sudo mysql だけでいいらしい。確かにアクセスできた。どういう設定でそうなってるのかはよくわからなかったが root でログインしたことになってた。初期化のエンドポイントは下記。

/api/initialize

これが叩かれると sql/init.sh を実行することになってる。テーブル作ったり初期データを流したりしている。テーブルの破棄はするが、再定義はしてない。データベース初期化の方法は提供されてなくて自前でやらないといけないらしい。

> DROP DATABASE isupipe および CREATE DATABASE isupipe で再作成し、
> $ cat webapp/sql/initdb.d/10_schema.sql | sudo mysql isupipe

powerDNS が必要とするテーブルとかは自動的に作られてて、今回のアプリケーションからスキーマ変更する手段は提供されてないみたいだ。つまり、sudo mysql でクライアント起動して自分でテーブル作ったりインデックス追加したりする必要があるように思う。ここまででわかってきたことを図にまとめる。

https://github.com/eggc/isucon13/wiki

# 3️⃣ ログ設定

## 各サービスのログ設定

mysql.conf にスロークエリログを設定して再起動。その後ログを確認。

```
sudo less /var/log/mysql/slow.log
```

nginx.conf にログ形式を変更して再起動。その後ログを確認。

```
sudo less /var/log/nginx/access.log
```

puma のログを確認。どうやら systemd で動いてるプロセスのログは journalctl で管理するらしい。

```
journalctl -u isupipe-ruby -f
```

## 分析コマンド

分析のためのコマンドが正しく動作することを確認したい。

```
make cleanlog
./bench run --enable-ssl
top
make after-bench
```

bench が約20秒。pt-query-digest が約40秒。
生のログファイルをアップロードしようとしたけど 400MB あったので無理だった。

```
2024-11-12T07:03:57.456Z	info	staff-logger	bench/bench.go:260	ベンチマーク走行時間: 1m0.877121689s
2024-11-12T07:03:57.456Z	info	isupipe-benchmarker	ベンチマーク走行終了
2024-11-12T07:03:57.456Z	info	isupipe-benchmarker	最終チェックを実施します
2024-11-12T07:03:57.456Z	info	isupipe-benchmarker	最終チェックが成功しました
2024-11-12T07:03:57.457Z	info	isupipe-benchmarker	重複排除したログを以下に出力します
2024-11-12T07:03:57.457Z	info	staff-logger	bench/bench.go:277	ベンチエラーを収集します
2024-11-12T07:03:57.457Z	info	staff-logger	bench/bench.go:285	内部エラーを収集します
2024-11-12T07:03:57.457Z	info	staff-logger	bench/bench.go:301	シナリオカウンタを出力します
2024-11-12T07:03:57.457Z	info	isupipe-benchmarker	配信を最後まで視聴できた視聴者数	{"viewers": 94}
2024-11-12T07:03:57.457Z	info	staff-logger	bench/bench.go:323	[シナリオ aggressive-streamer-moderate] 72 回成功, 2 回失敗
2024-11-12T07:03:57.457Z	info	staff-logger	bench/bench.go:323	[シナリオ dns-watertorture-attack] 196 回成功
2024-11-12T07:03:57.457Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-cold-reserve] 457 回成功, 1 回失敗
2024-11-12T07:03:57.457Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-moderate] 73 回成功, 1 回失敗
2024-11-12T07:03:57.457Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-report] 52 回成功, 3 回失敗
2024-11-12T07:03:57.457Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-spam] 74 回成功
2024-11-12T07:03:57.457Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer] 94 回成功, 10 回失敗
2024-11-12T07:03:57.457Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ aggressive-streamer-moderate-fail] 2 回失敗
2024-11-12T07:03:57.457Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-cold-reserve-fail] 1 回失敗
2024-11-12T07:03:57.457Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-moderate-fail] 1 回失敗
2024-11-12T07:03:57.457Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-fail] 10 回失敗
2024-11-12T07:03:57.457Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-report-fail] 3 回失敗
2024-11-12T07:03:57.457Z	info	staff-logger	bench/bench.go:329	DNSAttacker並列数: 9
2024-11-12T07:03:57.457Z	info	staff-logger	bench/bench.go:330	名前解決成功数: 22319
2024-11-12T07:03:57.457Z	info	staff-logger	bench/bench.go:331	名前解決失敗数: 183
2024-11-12T07:03:57.457Z	info	staff-logger	bench/bench.go:335	スコア: 19926
```

# 4️⃣ ログの分析とチューニング
## icons のインデックス

プロセスの様子を見ると mysqld が支配的だったので、クエリダイジェストを見る。
下記と同じ SQL が大量発行されてて、それが遅いようだ。

```sql
SELECT image FROM icons WHERE user_id = '1024'\G
```

```
EXPLAIN SELECT image FROM icons WHERE user_id = '1024';

+----+-------------+-------+------------+------+---------------+------+---------+------+------+----------+-------------+
| id | select_type | table | partitions | type | possible_keys | key  | key_len | ref  | rows | filtered | Extra       |
+----+-------------+-------+------------+------+---------------+------+---------+------+------+----------+-------------+
|  1 | SIMPLE      | icons | NULL       | ALL  | NULL          | NULL | NULL    | NULL |  623 |    10.00 | Using where |
+----+-------------+-------+------------+------+---------------+------+---------+------+------+----------+-------------+
```

確かにインデックス効いてない。インデックス入れて、再度確認。

```
CREATE INDEX idx_user_id ON icons(user_id);
EXPLAIN SELECT image FROM icons WHERE user_id = '1024';

+----+-------------+-------+------------+------+---------------+-------------+---------+-------+------+----------+-----------------------+
| id | select_type | table | partitions | type | possible_keys | key         | key_len | ref   | rows | filtered | Extra                 |
+----+-------------+-------+------------+------+---------------+-------------+---------+-------+------+----------+-----------------------+
|  1 | SIMPLE      | icons | NULL       | ref  | idx_user_id   | idx_user_id | 8       | const |    1 |   100.00 | Using index condition |
+----+-------------+-------+------------+------+---------------+-------------+---------+-------+------+----------+-----------------------+
```

ベンチマークを再実行してみた。

```
2024-11-12T07:37:34.202Z	info	staff-logger	bench/bench.go:260	ベンチマーク走行時間: 1m0.675977747s
2024-11-12T07:37:34.203Z	info	isupipe-benchmarker	ベンチマーク走行終了
2024-11-12T07:37:34.203Z	info	isupipe-benchmarker	最終チェックを実施します
2024-11-12T07:37:34.203Z	info	isupipe-benchmarker	最終チェックが成功しました
2024-11-12T07:37:34.203Z	info	isupipe-benchmarker	重複排除したログを以下に出力します
2024-11-12T07:37:34.203Z	info	staff-logger	bench/bench.go:277	ベンチエラーを収集します
2024-11-12T07:37:34.203Z	info	staff-logger	bench/bench.go:285	内部エラーを収集します
2024-11-12T07:37:34.203Z	info	staff-logger	bench/bench.go:301	シナリオカウンタを出力します
2024-11-12T07:37:34.203Z	info	isupipe-benchmarker	配信を最後まで視聴できた視聴者数	{"viewers": 124}
2024-11-12T07:37:34.203Z	info	staff-logger	bench/bench.go:323	[シナリオ aggressive-streamer-moderate] 89 回成功
2024-11-12T07:37:34.203Z	info	staff-logger	bench/bench.go:323	[シナリオ dns-watertorture-attack] 207 回成功
2024-11-12T07:37:34.203Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-cold-reserve] 475 回成功
2024-11-12T07:37:34.203Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-moderate] 81 回成功, 1 回失敗
2024-11-12T07:37:34.203Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-report] 49 回成功, 7 回失敗
2024-11-12T07:37:34.203Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-spam] 90 回成功, 1 回失敗
2024-11-12T07:37:34.203Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer] 124 回成功
2024-11-12T07:37:34.203Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-moderate-fail] 1 回失敗
2024-11-12T07:37:34.203Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-report-fail] 7 回失敗
2024-11-12T07:37:34.203Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-spam-fail] 1 回失敗
2024-11-12T07:37:34.203Z	info	staff-logger	bench/bench.go:329	DNSAttacker並列数: 13
2024-11-12T07:37:34.203Z	info	staff-logger	bench/bench.go:330	名前解決成功数: 24021
2024-11-12T07:37:34.203Z	info	staff-logger	bench/bench.go:331	名前解決失敗数: 99
2024-11-12T07:37:34.203Z	info	staff-logger	bench/bench.go:335	スコア: 25468
```

## livestream_tags のインデックス

下記も同じようにインデックスを追加すればよさそう。

```sql
SELECT * FROM livestream_tags WHERE livestream_id = '7541'\G
```

```
EXPLAIN SELECT * FROM livestream_tags WHERE livestream_id = '7541';
+----+-------------+-----------------+------------+------+---------------+------+---------+------+-------+----------+-------------+
| id | select_type | table           | partitions | type | possible_keys | key  | key_len | ref  | rows  | filtered | Extra       |
+----+-------------+-----------------+------------+------+---------------+------+---------+------+-------+----------+-------------+
|  1 | SIMPLE      | livestream_tags | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 13425 |    10.00 | Using where |
+----+-------------+-----------------+------------+------+---------------+------+---------+------+-------+----------+-------------+
1 row in set, 1 warning (0.00 sec)
```

```
CREATE INDEX idx_livestream_id ON livestream_tags(livestream_id);

EXPLAIN SELECT * FROM livestream_tags WHERE livestream_id = '7541';
+----+-------------+-----------------+------------+------+-------------------+-------------------+---------+-------+------+----------+-----------------------+
| id | select_type | table           | partitions | type | possible_keys     | key               | key_len | ref   | rows | filtered | Extra                 |
+----+-------------+-----------------+------------+------+-------------------+-------------------+---------+-------+------+----------+-----------------------+
|  1 | SIMPLE      | livestream_tags | NULL       | ref  | idx_livestream_id | idx_livestream_id | 8       | const |    5 |   100.00 | Using index condition |
+----+-------------+-----------------+------------+------+-------------------+-------------------+---------+-------+------+----------+-----------------------+
1 row in set, 1 warning (0.00 sec)
```

```
2024-11-12T07:46:52.216Z	info	staff-logger	bench/bench.go:260	ベンチマーク走行時間: 1m0.63363704s
2024-11-12T07:46:52.216Z	info	isupipe-benchmarker	ベンチマーク走行終了
2024-11-12T07:46:52.216Z	info	isupipe-benchmarker	最終チェックを実施します
2024-11-12T07:46:52.216Z	info	isupipe-benchmarker	最終チェックが成功しました
2024-11-12T07:46:52.216Z	info	isupipe-benchmarker	重複排除したログを以下に出力します
2024-11-12T07:46:52.216Z	info	staff-logger	bench/bench.go:277	ベンチエラーを収集します
2024-11-12T07:46:52.216Z	info	staff-logger	bench/bench.go:285	内部エラーを収集します
2024-11-12T07:46:52.216Z	info	staff-logger	bench/bench.go:301	シナリオカウンタを出力します
2024-11-12T07:46:52.216Z	info	isupipe-benchmarker	配信を最後まで視聴できた視聴者数	{"viewers": 148}
2024-11-12T07:46:52.216Z	info	staff-logger	bench/bench.go:323	[シナリオ aggressive-streamer-moderate] 79 回成功, 1 回失敗
2024-11-12T07:46:52.216Z	info	staff-logger	bench/bench.go:323	[シナリオ dns-watertorture-attack] 202 回成功
2024-11-12T07:46:52.216Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-cold-reserve] 482 回成功
2024-11-12T07:46:52.216Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-moderate] 164 回成功, 1 回失敗
2024-11-12T07:46:52.216Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-report] 50 回成功, 6 回失敗
2024-11-12T07:46:52.216Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-spam] 81 回成功, 1 回失敗
2024-11-12T07:46:52.216Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer] 148 回成功
2024-11-12T07:46:52.216Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ aggressive-streamer-moderate-fail] 1 回失敗
2024-11-12T07:46:52.216Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-moderate-fail] 1 回失敗
2024-11-12T07:46:52.216Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-report-fail] 6 回失敗
2024-11-12T07:46:52.216Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-spam-fail] 1 回失敗
2024-11-12T07:46:52.216Z	info	staff-logger	bench/bench.go:329	DNSAttacker並列数: 13
2024-11-12T07:46:52.216Z	info	staff-logger	bench/bench.go:330	名前解決成功数: 23469
2024-11-12T07:46:52.216Z	info	staff-logger	bench/bench.go:331	名前解決失敗数: 1
2024-11-12T07:46:52.216Z	info	staff-logger	bench/bench.go:335	スコア: 29923
```

まだ mysqld のプロセスが支配的。

## records のインデックス

```sql
SELECT content,ttl,prio,type,domain_id,disabled,name,auth FROM records WHERE disabled=0 and name='nxkhz95d2ug90z7sn30.u.isucon.local' and domain_id=1\G
```

どうやら powerDNS のクエリが飛んできているようだ。

```
EXPLAIN SELECT content,ttl,prio,type,domain_id,disabled,name,auth FROM records WHERE disabled=0 and name='nxkhz95d2ug90z7sn30.u.isucon.local' and domain_id=1 and type="A"\G

*************************** 1. row ***************************
           id: 1
  select_type: SIMPLE
        table: records
   partitions: NULL
         type: ALL
possible_keys: domain_id
          key: NULL
      key_len: NULL
          ref: NULL
         rows: 1995
     filtered: 1.00
        Extra: Using where
1 row in set, 1 warning (0.00 sec)
```

これも name でインデックスつければいいのかな。isudns のデータベース初期化はいつやるとも書いてないので扱いが難しい。

```
CREATE INDEX name_index ON records(name);

EXPLAIN SELECT content,ttl,prio,type,domain_id,disabled,name,auth FROM records WHERE disabled=0 and name='nxkhz95d2ug90z7sn30.u.isucon.local' and domain_id=1 and type="A"\G
*************************** 1. row ***************************
           id: 1
  select_type: SIMPLE
        table: records
   partitions: NULL
         type: ref
possible_keys: domain_id,name_index
          key: name_index
      key_len: 258
          ref: const
         rows: 1
     filtered: 5.00
        Extra: Using where
1 row in set, 1 warning (0.01 sec)
```

まだ mysqld が支配的な感じがする。少しスコアが下がったが、名前解決の成功数は増えている。

```
2024-11-12T08:14:15.118Z	info	staff-logger	bench/bench.go:260	ベンチマーク走行時間: 1m0.576192157s
2024-11-12T08:14:15.118Z	info	isupipe-benchmarker	ベンチマーク走行終了
2024-11-12T08:14:15.119Z	info	isupipe-benchmarker	最終チェックを実施します
2024-11-12T08:14:15.119Z	info	isupipe-benchmarker	最終チェックが成功しました
2024-11-12T08:14:15.119Z	info	isupipe-benchmarker	重複排除したログを以下に出力します
2024-11-12T08:14:15.119Z	info	staff-logger	bench/bench.go:277	ベンチエラーを収集します
2024-11-12T08:14:15.119Z	info	staff-logger	bench/bench.go:285	内部エラーを収集します
2024-11-12T08:14:15.119Z	info	staff-logger	bench/bench.go:301	シナリオカウンタを出力します
2024-11-12T08:14:15.119Z	info	isupipe-benchmarker	配信を最後まで視聴できた視聴者数	{"viewers": 131}
2024-11-12T08:14:15.119Z	info	staff-logger	bench/bench.go:323	[シナリオ aggressive-streamer-moderate] 99 回成功, 1 回失敗
2024-11-12T08:14:15.119Z	info	staff-logger	bench/bench.go:323	[シナリオ dns-watertorture-attack] 639 回成功
2024-11-12T08:14:15.119Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-cold-reserve] 645 回成功
2024-11-12T08:14:15.119Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-moderate] 137 回成功, 1 回失敗
2024-11-12T08:14:15.119Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-report] 53 回成功, 4 回失敗
2024-11-12T08:14:15.119Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-spam] 101 回成功, 1 回失敗
2024-11-12T08:14:15.119Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer] 131 回成功
2024-11-12T08:14:15.119Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ aggressive-streamer-moderate-fail] 1 回失敗
2024-11-12T08:14:15.119Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-moderate-fail] 1 回失敗
2024-11-12T08:14:15.119Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-report-fail] 4 回失敗
2024-11-12T08:14:15.119Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-spam-fail] 1 回失敗
2024-11-12T08:14:15.119Z	info	staff-logger	bench/bench.go:329	DNSAttacker並列数: 15
2024-11-12T08:14:15.119Z	info	staff-logger	bench/bench.go:330	名前解決成功数: 68582
2024-11-12T08:14:15.119Z	info	staff-logger	bench/bench.go:331	名前解決失敗数: 1
2024-11-12T08:14:15.119Z	info	staff-logger	bench/bench.go:335	スコア: 26609
```

## livecomments のインデックス

一番重いクエリは下記になった。集計関数が含まれている。
ユーザのライブに含まれるライブコメントのチップの総数を集計している。

```sql
SELECT IFNULL(SUM(l2.tip), 0) FROM users u
INNER JOIN livestreams l ON l.user_id = u.id
INNER JOIN livecomments l2 ON l2.livestream_id = l.id
WHERE u.id = '151'\G
```

これも explain かけてみよう。

```
explain SELECT IFNULL(SUM(l2.tip), 0) FROM users u INNER JOIN livestreams l ON l.user_id = u.id INNER JOIN livecomments l2 ON l2.livestream_id = l.id WHERE u.id = '151';
+----+-------------+-------+------------+--------+---------------+---------+---------+--------------------------+------+----------+-------------+
| id | select_type | table | partitions | type   | possible_keys | key     | key_len | ref                      | rows | filtered | Extra       |
+----+-------------+-------+------------+--------+---------------+---------+---------+--------------------------+------+----------+-------------+
|  1 | SIMPLE      | u     | NULL       | const  | PRIMARY       | PRIMARY | 8       | const                    |    1 |   100.00 | Using index |
|  1 | SIMPLE      | l2    | NULL       | ALL    | NULL          | NULL    | NULL    | NULL                     | 2601 |   100.00 | NULL        |
|  1 | SIMPLE      | l     | NULL       | eq_ref | PRIMARY       | PRIMARY | 8       | isupipe.l2.livestream_id |    1 |    10.00 | Using where |
+----+-------------+-------+------------+--------+---------------+---------+---------+--------------------------+------+----------+-------------+
3 rows in set, 1 warning (0.00 sec)
```

l2 の rows が高い数値になってるので l2 の絞り込み条件にインデックスを追加すれば効果がありそう。

```sql
CREATE INDEX livestream_id_index ON livecomments(livestream_id);
```

しかし explain の結果が変わらない。なぜだろう。あ、これ l の方もインデックスたりてないんじゃないか。

```sql
CREATE INDEX user_id_index ON livestreams(user_id);
```

インデックス効くようになった。

```
explain SELECT IFNULL(SUM(l2.tip), 0) FROM users u INNER JOIN livestreams l ON l.user_id = u.id INNER JOIN livecomments l2 ON l2.livestream_id = l.id WHERE u.id = '151';
+----+-------------+-------+------------+-------+-----------------------+---------------------+---------+--------------+------+----------+--------------------------+
| id | select_type | table | partitions | type  | possible_keys         | key                 | key_len | ref          | rows | filtered | Extra                    |
+----+-------------+-------+------------+-------+-----------------------+---------------------+---------+--------------+------+----------+--------------------------+
|  1 | SIMPLE      | u     | NULL       | const | PRIMARY               | PRIMARY             | 8       | const        |    1 |   100.00 | Using index              |
|  1 | SIMPLE      | l     | NULL       | ref   | PRIMARY,user_id_index | user_id_index       | 8       | const        |    8 |   100.00 | Using where; Using index |
|  1 | SIMPLE      | l2    | NULL       | ref   | livestream_id_index   | livestream_id_index | 8       | isupipe.l.id |    2 |   100.00 | NULL                     |
+----+-------------+-------+------------+-------+-----------------------+---------------------+---------+--------------+------+----------+--------------------------+
3 rows in set, 1 warning (0.00 sec)
```
