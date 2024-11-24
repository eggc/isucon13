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

sudo mysql だけでいいらしい。確かにアクセスできた。
これは root ユーザかつソケット接続になるらしい。ソケット接続だけ許可してて TCP 接続だとダメらしい。
sudo mysql --protocol=tcp だと失敗する。

初期化のエンドポイントは下記。

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

```
2024-11-12T08:54:04.726Z	info	staff-logger	bench/bench.go:260	ベンチマーク走行時間: 1m0.27903132s
2024-11-12T08:54:04.727Z	info	isupipe-benchmarker	ベンチマーク走行終了
2024-11-12T08:54:04.727Z	info	isupipe-benchmarker	最終チェックを実施します
2024-11-12T08:54:04.727Z	info	isupipe-benchmarker	最終チェックが成功しました
2024-11-12T08:54:04.727Z	info	isupipe-benchmarker	重複排除したログを以下に出力します
2024-11-12T08:54:04.727Z	info	staff-logger	bench/bench.go:277	ベンチエラーを収集します
2024-11-12T08:54:04.727Z	info	staff-logger	bench/bench.go:285	内部エラーを収集します
2024-11-12T08:54:04.727Z	info	staff-logger	bench/bench.go:301	シナリオカウンタを出力します
2024-11-12T08:54:04.727Z	info	isupipe-benchmarker	配信を最後まで視聴できた視聴者数	{"viewers": 190}
2024-11-12T08:54:04.727Z	info	staff-logger	bench/bench.go:323	[シナリオ aggressive-streamer-moderate] 101 回成功, 1 回失敗
2024-11-12T08:54:04.727Z	info	staff-logger	bench/bench.go:323	[シナリオ dns-watertorture-attack] 685 回成功
2024-11-12T08:54:04.727Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-cold-reserve] 743 回成功
2024-11-12T08:54:04.727Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-moderate] 131 回成功
2024-11-12T08:54:04.727Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-report] 54 回成功, 3 回失敗
2024-11-12T08:54:04.727Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-spam] 104 回成功
2024-11-12T08:54:04.727Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer] 190 回成功
2024-11-12T08:54:04.727Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ aggressive-streamer-moderate-fail] 1 回失敗
2024-11-12T08:54:04.727Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-report-fail] 3 回失敗
2024-11-12T08:54:04.727Z	info	staff-logger	bench/bench.go:329	DNSAttacker並列数: 15
2024-11-12T08:54:04.727Z	info	staff-logger	bench/bench.go:330	名前解決成功数: 73736
2024-11-12T08:54:04.727Z	info	staff-logger	bench/bench.go:331	名前解決失敗数: 0
2024-11-12T08:54:04.727Z	info	staff-logger	bench/bench.go:335	スコア: 37145
```

まだ mysqld が支配的なんだけど時々 puma の worker も上位に来るようになってきた。

## reactions のインデックス

```sql
SELECT COUNT(*) FROM users u
INNER JOIN livestreams l ON l.user_id = u.id
INNER JOIN reactions r ON r.livestream_id = l.id
WHERE u.id = '585'\G
```

やはりインデックスかかってない

```
EXPLAIN SELECT COUNT(*) FROM users u INNER JOIN livestreams l ON l.user_id = u.id INNER JOIN reactions r ON r.livestream_id = l.id WHERE u.id = '585';
+----+-------------+-------+------------+--------+-----------------------+---------+---------+-------------------------+------+----------+-------------+
| id | select_type | table | partitions | type   | possible_keys         | key     | key_len | ref                     | rows | filtered | Extra       |
+----+-------------+-------+------------+--------+-----------------------+---------+---------+-------------------------+------+----------+-------------+
|  1 | SIMPLE      | u     | NULL       | const  | PRIMARY               | PRIMARY | 8       | const                   |    1 |   100.00 | Using index |
|  1 | SIMPLE      | r     | NULL       | ALL    | NULL                  | NULL    | NULL    | NULL                    | 2969 |   100.00 | NULL        |
|  1 | SIMPLE      | l     | NULL       | eq_ref | PRIMARY,user_id_index | PRIMARY | 8       | isupipe.r.livestream_id |    1 |     5.00 | Using where |
+----+-------------+-------+------------+--------+-----------------------+---------+---------+-------------------------+------+----------+-------------+
3 rows in set, 1 warning (0.00 sec)
```

```sql
CREATE INDEX livestream_id_index ON reactions(livestream_id)
```

改善した。

```
explain SELECT COUNT(*) FROM users u INNER JOIN livestreams l ON l.user_id = u.id INNER JOIN reactions r ON r.livestream_id = l.id WHERE u.id = '585';
+----+-------------+-------+------------+-------+-----------------------+---------------------+---------+--------------+------+----------+--------------------------+
| id | select_type | table | partitions | type  | possible_keys         | key                 | key_len | ref          | rows | filtered | Extra                    |
+----+-------------+-------+------------+-------+-----------------------+---------------------+---------+--------------+------+----------+--------------------------+
|  1 | SIMPLE      | u     | NULL       | const | PRIMARY               | PRIMARY             | 8       | const        |    1 |   100.00 | Using index              |
|  1 | SIMPLE      | l     | NULL       | ref   | PRIMARY,user_id_index | user_id_index       | 8       | const        |    7 |   100.00 | Using where; Using index |
|  1 | SIMPLE      | r     | NULL       | ref   | livestream_id_index   | livestream_id_index | 8       | isupipe.l.id |    2 |   100.00 | Using index              |
+----+-------------+-------+------------+-------+-----------------------+---------------------+---------+--------------+------+----------+--------------------------+
3 rows in set, 1 warning (0.01 sec)
```

これで puma と powerdns のプロセスが上位に来るようになった。
ただ、まだインデックスだけで改善できる箇所が残ってるようなので続ける。

```
2024-11-12T09:04:24.908Z	info	staff-logger	bench/bench.go:260	ベンチマーク走行時間: 1m0.245315342s
2024-11-12T09:04:24.908Z	info	isupipe-benchmarker	ベンチマーク走行終了
2024-11-12T09:04:24.908Z	info	isupipe-benchmarker	最終チェックを実施します
2024-11-12T09:04:24.910Z	info	isupipe-benchmarker	最終チェックが成功しました
2024-11-12T09:04:24.910Z	info	isupipe-benchmarker	重複排除したログを以下に出力します
2024-11-12T09:04:24.910Z	info	staff-logger	bench/bench.go:277	ベンチエラーを収集します
2024-11-12T09:04:24.910Z	info	staff-logger	bench/bench.go:285	内部エラーを収集します
2024-11-12T09:04:24.910Z	info	staff-logger	bench/bench.go:301	シナリオカウンタを出力します
2024-11-12T09:04:24.910Z	info	isupipe-benchmarker	配信を最後まで視聴できた視聴者数	{"viewers": 222}
2024-11-12T09:04:24.910Z	info	staff-logger	bench/bench.go:323	[シナリオ aggressive-streamer-moderate] 87 回成功
2024-11-12T09:04:24.910Z	info	staff-logger	bench/bench.go:323	[シナリオ dns-watertorture-attack] 678 回成功
2024-11-12T09:04:24.910Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-cold-reserve] 769 回成功, 1 回失敗
2024-11-12T09:04:24.910Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-moderate] 115 回成功, 1 回失敗
2024-11-12T09:04:24.910Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-report] 51 回成功, 6 回失敗
2024-11-12T09:04:24.910Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-spam] 88 回成功
2024-11-12T09:04:24.910Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer] 222 回成功, 7 回失敗
2024-11-12T09:04:24.910Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-cold-reserve-fail] 1 回失敗
2024-11-12T09:04:24.910Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-moderate-fail] 1 回失敗
2024-11-12T09:04:24.910Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-fail] 7 回失敗
2024-11-12T09:04:24.910Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-report-fail] 6 回失敗
2024-11-12T09:04:24.910Z	info	staff-logger	bench/bench.go:329	DNSAttacker並列数: 15
2024-11-12T09:04:24.910Z	info	staff-logger	bench/bench.go:330	名前解決成功数: 72549
2024-11-12T09:04:24.910Z	info	staff-logger	bench/bench.go:331	名前解決失敗数: 0
2024-11-12T09:04:24.910Z	info	staff-logger	bench/bench.go:335	スコア: 43605
```

## themes のインデックス

```
EXPLAIN SELECT * FROM themes WHERE user_id = '1349';
+----+-------------+--------+------------+------+---------------+------+---------+------+------+----------+-------------+
| id | select_type | table  | partitions | type | possible_keys | key  | key_len | ref  | rows | filtered | Extra       |
+----+-------------+--------+------------+------+---------------+------+---------+------+------+----------+-------------+
|  1 | SIMPLE      | themes | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 2378 |    10.00 | Using where |
+----+-------------+--------+------------+------+---------------+------+---------+------+------+----------+-------------+
1 row in set, 1 warning (0.00 sec)
```

```sql
CREATE INDEX user_id_index ON themes(user_id)
```

```
EXPLAIN SELECT * FROM themes WHERE user_id = '1349';
+----+-------------+--------+------------+------+---------------+---------------+---------+-------+------+----------+-----------------------+
| id | select_type | table  | partitions | type | possible_keys | key           | key_len | ref   | rows | filtered | Extra                 |
+----+-------------+--------+------------+------+---------------+---------------+---------+-------+------+----------+-----------------------+
|  1 | SIMPLE      | themes | NULL       | ref  | user_id_index | user_id_index | 8       | const |    1 |   100.00 | Using index condition |
+----+-------------+--------+------------+------+---------------+---------------+---------+-------+------+----------+-----------------------+
1 row in set, 1 warning (0.00 sec)
```

## reservation_slots のインデックス

```
EXPLAIN SELECT slot FROM reservation_slots WHERE start_at = '1705050000' AND end_at = '1705053600';

+----+-------------+-------------------+------------+------+---------------+------+---------+------+------+----------+-------------+
| id | select_type | table             | partitions | type | possible_keys | key  | key_len | ref  | rows | filtered | Extra       |
+----+-------------+-------------------+------------+------+---------------+------+---------+------+------+----------+-------------+
|  1 | SIMPLE      | reservation_slots | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 8593 |     1.00 | Using where |
+----+-------------+-------------------+------------+------+---------------+------+---------+------+------+----------+-------------+
1 row in set, 1 warning (0.00 sec)
```

```sql
CREATE INDEX start_at_and_end_at_index ON reservation_slots(start_at, end_at)
```

```
EXPLAIN SELECT slot FROM reservation_slots WHERE start_at = '1705050000' AND end_at = '1705053600';
+----+-------------+-------------------+------------+------+---------------------------+---------------------------+---------+-------------+------+----------+-----------------------+
| id | select_type | table             | partitions | type | possible_keys             | key                       | key_len | ref         | rows | filtered | Extra                 |
+----+-------------+-------------------+------------+------+---------------------------+---------------------------+---------+-------------+------+----------+-----------------------+
|  1 | SIMPLE      | reservation_slots | NULL       | ref  | start_at_and_end_at_index | start_at_and_end_at_index | 16      | const,const |    1 |   100.00 | Using index condition |
+----+-------------+-------------------+------------+------+---------------------------+---------------------------+---------+-------------+------+----------+-----------------------+
```

## GET /api/livestream/*/livecomment の改善

mysql の方は改善されたようなので alp を眺めてみる。遅いエンドポイントは下記の5個。

```
+-------+-----+-------+-----+-----+-----+--------+-------------------------------------------+-------+-------+---------+-------+-------+-------+-------+--------+-----------+------------+----------------+-----------+
| COUNT | 1XX |  2XX  | 3XX | 4XX | 5XX | METHOD |                    URI                    |  MIN  |  MAX  |   SUM   |  AVG  |  P90  |  P95  |  P99  | STDDEV | MIN(BODY) | MAX(BODY)  |   SUM(BODY)    | AVG(BODY) |
+-------+-----+-------+-----+-----+-----+--------+-------------------------------------------+-------+-------+---------+-------+-------+-------+-------+--------+-----------+------------+----------------+-----------+
|  2773 |   0 |  2771 |   0 |   2 |   0 | GET    | ^/api/livestream/.*/livecomment           | 0.001 | 0.382 | 126.470 | 0.046 | 0.099 | 0.125 | 0.185 |  0.041 |     0.000 |  57152.000 |   30584507.000 | 11029.393 |
|  2808 |   0 |  2805 |   0 |   3 |   0 | GET    | ^/api/livestream/.*/reaction              | 0.001 | 0.324 | 123.697 | 0.044 | 0.096 | 0.120 | 0.182 |  0.040 |     0.000 |  54646.000 |   28637542.000 | 10198.555 |
|   141 |   0 |   138 |   0 |   3 |   0 | POST   | ^/api/livestream/.*/moderate              | 0.052 | 1.897 |  98.679 | 0.700 | 1.056 | 1.163 | 1.825 |  0.319 |     0.000 |     17.000 |       2346.000 |    16.638 |
| 22331 |   0 | 22330 |   0 |   1 |   0 | GET    | ^/api/user/.*/icon                        | 0.001 | 0.074 |  91.389 | 0.004 | 0.007 | 0.008 | 0.012 |  0.003 |     0.000 | 171652.000 | 1313994817.000 | 58841.736 |
|   448 |   0 |   447 |   0 |   1 |   0 | GET    | ^/api/livestream/search                   | 0.014 | 0.581 |  80.776 | 0.180 | 0.230 | 0.288 | 0.425 |  0.064 |     0.000 | 147849.000 |   23550426.000 | 52567.915 |
```

ライブコメントのところを見てみよう。見た感じ2重ループでSQLを発行しているのでN+1クエリとなっている。

- get '/api/livestream/:livestream_id/livecomment'
  - fill_livecomment_response
    - fill_user_response
      - 'SELECT * FROM themes WHERE user_id = ?'
      - 'SELECT image FROM icons WHERE user_id = ?'
    - fill_livestream_response
      - 'SELECT * FROM users WHERE id = ?'
      - 'SELECT * FROM livestream_tags WHERE livestream_id = ?'
      - 'SELECT * FROM tags WHERE id = ?'

これかなりややこしいので fill_livecomment_response がどんなふうに振る舞うのかを console で試せるようにした。

b /home/isucon/webapp/ruby/app.rb:485
$rack.get('/api/livestream/2/livecomment')

```json
[{"id"=>543,
  "comment"=>"明日、眠そうだけど楽しかった！",
  "tip"=>0,
  "created_at"=>1731417782,
  "user"=>
   {"id"=>3,
    "name"=>"yoshidamiki0",
    "display_name"=>"ひまわりひめ",
    "description"=>"普段演歌歌手をしています。\nよろしくおねがいします！\n\n連絡は以下からお願いします。\n\nウェブサイト: http://yoshidamiki.example.com/\nメールアドレス: yoshidamiki@example.com\n",
    "theme"=>{"id"=>3, "dark_mode"=>false},
    "icon_hash"=>"d9f8294e9d895f81ce62e73dc7d5dff862a4fa40bd4e0fecf53f7526a8edcac0"},
  "livestream"=>
   {"id"=>2,
    "title"=>"映画レビュー！最新映画の感想を語る",
    "description"=>"最新の映画について、感想や考察を深く掘り下げて話していきます。",
    "playlist_url"=>"https://media.xiii.isucon.dev/api/7/playlist.m3u8",
    "thumbnail_url"=>"https://media.xiii.isucon.dev/yoru.webp",
    "start_at"=>1690851600,
    "end_at"=>1690855200,
    "owner"=>
     {"id"=>3,
      "name"=>"yoshidamiki0",
      "display_name"=>"ひまわりひめ",
      "description"=>"普段演歌歌手をしています。\nよろしくおねがいします！\n\n連絡は以下からお願いします。\n\nウェブサイト: http://yoshidamiki.example.com/\nメールアドレス: yoshidamiki@example.com\n",
      "theme"=>{"id"=>3, "dark_mode"=>false},
      "icon_hash"=>"d9f8294e9d895f81ce62e73dc7d5dff862a4fa40bd4e0fecf53f7526a8edcac0"},
    "tags"=>[{"id"=>98, "name"=>"コラボ配信"}, {"id"=>5, "name"=>"初心者歓迎"}]}}]
```

desciption を削ったら仕様違反になったが theme を削るのはアリだった。
ていうか theme 使用箇所限られてるし user テーブルとくっつけてしまってまとめて取れるようにしてもいい気がする。
影響範囲が広くなるのでリスキーだ。 fill_user_response にフラグつけて theme なしを可能にしてみるか。
少し効果はあったけどN+1クエリがなくならない限りはまだまだ伸びないようだ。

## GET /api/livestream/*/livecomment の改善2

livecomment_models = tx.xquery('SELECT * FROM livecomments WHERE livestream_id = 2 ORDER BY created_at DESC')
fill_livecomment_response(tx, livecomment_models.first)
fill_livecomment_responses(tx, livecomment_models)

fill_user_response と fill_livecomment_response の IN 句を使うバージョンを作ってみよう。

- get '/api/livestream/:livestream_id/livecomment'
  - fill_livecomment_response
    - fill_user_response
      - 'SELECT * FROM themes WHERE user_id = ?'
      - 'SELECT image FROM icons WHERE user_id = ?'
    - fill_livestream_response
      - 'SELECT * FROM users WHERE id = ?'
      - 'SELECT * FROM livestream_tags WHERE livestream_id = ?'
      - 'SELECT * FROM tags WHERE id = ?'

500 エラーが出てしまったのでログを見る。

{"pass":false,"score":0,"messages":["整合性チェックに失敗しました","benchmark-application: [一般エラー] GET /api/livestream/7499/livecomment へのリクエストに対して、期待されたHTTPステータスコードが確認できませんでした (expected:200, actual:500)","[一般エラー] GET /api/livestream/7499/livecomment へのリクエストに対して、期待されたHTTPステータスコードが確認できませんでした (expected:200, actual:500)"],"language":"ruby","resolved_count":0}

journalctl -u isupipe-ruby -n200 でログを見た。スタックトレースが出ているので、これを参考にして原因を探す。

```
Mysql2::Error - You have an error in your SQL syntax;
/home/isucon/webapp/ruby/app.rb:125:in `fill_livecomment_responses'
/home/isucon/webapp/ruby/app.rb:536
```

下記の方法でデバッグ

```ruby
$rack.get('/api/livestream/7499/livecomment')

tx = $rack.app.new.helpers.db_conn
query = 'SELECT * FROM livecomments WHERE livestream_id = ? ORDER BY created_at DESC'
livestream_id = 7499.to_i
livecomment_models = tx.xquery(query, livestream_id)
```

一つもコメントがない場合のケースを対応できてなかったので修正してベンチマーク成功。

## iconの改善1

アプリケーションガイドによると、下記のエンドポイントでは If-None-Match ヘッダがついていることがあり、その場合は 304 を返すことができるらしい。

get '/api/user/:username/icon'

304 を実装してみよう。

```ruby
binding.irb
debug
b /home/isucon/webapp/ruby/app.rb:787

$rack.get('/api/user/test001')

JSON.parse($rack.get('/api/user/test001').body)["icon_hash"]
#=> "1225d203cd3871dec173cb6a4f7aec1202f2880f903874e3495a4d5248d0c60d"

$rack.header("If-None-Match", "1225d203cd3871dec173cb6a4f7aec1202f2880f903874e3495a4d5248d0c60d")
$rack.get('/api/user/test001/icon')
```

ログのレスポンスでは status:304 が含まれていない。If-None-Match を含むリクエストが存在するのかどうか、確認してみよう。
nginx のログで request header の中身を出力するようにしてみよう。$http_if_none_match を書き込むと、確かにでた。
ハッシュ値が \x22 というので囲まれていた。ドキュメントを見ると `"` で囲まれていた。実際のリクエストもそうなっているようだ。これを考慮しなければならない。

少し改善した。

## iconの改善2

304を返すときに icon テーブルからバイナリを読み出して毎回 hexdigest をとっていたので内部コストが高いと考えた。
そこで users テーブルに icon_hash カラムを追加して、 hexdigest の結果を保存しておくことにした。
アイコン更新時に、このカラムを更新することで常に最新の値を持つようにした。

## iconの改善3

icon_hash を返すべき場面で毎回計算するのではなくて users テーブルに格納している計算結果を使うようにする。
しかし一度もアイコン設定してない場合に仕様違反になってしまったので修正。

JSON.parse($rack.get('/api/livestream/7508/livecomment').body)

あらかじめ計算しておいて users テーブルの icon_hash カラムのデフォルト値ということにしてみる。

```ruby
FALLBACK_IMAGE = '../img/NoImage.jpg'
image = File.binread(FALLBACK_IMAGE)
icon_hash = Digest::SHA256.hexdigest(image)

#=> "d9f8294e9d895f81ce62e73dc7d5dff862a4fa40bd4e0fecf53f7526a8edcac0"
```

## GET '/api/livestream/:livestream_id/reaction' の改善

```
+-------+-----+------+-------+-----+-----+--------+-------------------------------------------+-------+-------+---------+-------+-------+-------+-------+--------+-----------+------------+--------------+-----------+
| COUNT | 1XX | 2XX  |  3XX  | 4XX | 5XX | METHOD |                    URI                    |  MIN  |  MAX  |   SUM   |  AVG  |  P90  |  P95  |  P99  | STDDEV | MIN(BODY) | MAX(BODY)  |  SUM(BODY)   | AVG(BODY) |
+-------+-----+------+-------+-----+-----+--------+-------------------------------------------+-------+-------+---------+-------+-------+-------+-------+--------+-----------+------------+--------------+-----------+
|   138 |   0 |  136 |     0 |   2 |   0 | POST   | ^/api/livestream/.*/moderate              | 0.052 | 1.504 | 106.560 | 0.772 | 1.219 | 1.334 | 1.477 |  0.313 |     0.000 |     17.000 |     2312.000 |    16.754 |
|  4220 |   0 | 4218 |     0 |   2 |   0 | GET    | ^/api/livestream/.*/reaction              | 0.001 | 0.177 | 105.823 | 0.025 | 0.054 | 0.070 | 0.099 |  0.022 |     0.000 |  60814.000 | 47867246.000 | 11342.949 |
|    25 |   0 |   23 |     0 |   2 |   0 | GET    | ^/api/livestream/.*/statistics            | 0.813 | 4.942 | 100.497 | 4.020 | 4.674 | 4.809 | 4.942 |  1.118 |     0.000 |     83.000 |     1866.000 |    74.640 |
```

シンプルに N+1 クエリが発生しているので livecomment の対応の時と同じことをすればよさそう

```ruby
tx = $rack.app.new.helpers.db_conn
query = 'SELECT * FROM reactions WHERE livestream_id = ? ORDER BY created_at DESC'
livestream_id = 5849
reaction_models = tx.xquery(query, livestream_id)

# 既存のコードの振る舞い
$rack.app.new.helpers.fill_reaction_response(tx, reaction_models.first)

# 期待するコードの振る舞い
class Isupipe::App
  helpers do
    def fill_reaction_responses(tx, reaction_models)
      ... ここに書く ...
    end
  end
end

$rack.app.new.helpers.fill_reaction_responses(tx, reaction_models)
```

ライブストリーム id は全て同じだから一回ひいて再利用できる。
スコアが少し改善した。

## POST '/api/livestream/:livestream_id/moderate' の改善

NG ワード登録されると、ライブコメントの削除が行われる。
その削除SQLがコストが高いようだ。

```
+-------+-----+------+-------+-----+-----+--------+-------------------------------------------+-------+-------+---------+-------+-------+-------+-------+--------+-----------+------------+--------------+-----------+
| COUNT | 1XX | 2XX  |  3XX  | 4XX | 5XX | METHOD |                    URI                    |  MIN  |  MAX  |   SUM   |  AVG  |  P90  |  P95  |  P99  | STDDEV | MIN(BODY) | MAX(BODY)  |  SUM(BODY)   | AVG(BODY) |
+-------+-----+------+-------+-----+-----+--------+-------------------------------------------+-------+-------+---------+-------+-------+-------+-------+--------+-----------+------------+--------------+-----------+
|   115 |   0 |  112 |     0 |   3 |   0 | POST   | ^/api/livestream/.*/moderate              | 0.053 | 3.947 | 121.625 | 1.058 | 2.559 | 2.834 | 3.309 |  0.809 |     0.000 |     17.000 |     1904.000 |    16.557 |
|    27 |   0 |   25 |     0 |   2 |   0 | GET    | ^/api/livestream/.*/statistics            | 0.598 | 6.250 | 120.783 | 4.473 | 6.200 | 6.241 | 6.250 |  1.569 |     0.000 |     82.000 |     2022.000 |    74.889 |
```

重たいとされているクエリが複雑でよくわからない。

```sql
DELETE FROM livecomments
WHERE
id = '1243' AND
livestream_id = '7662' AND
(SELECT COUNT(*)
  FROM
  (SELECT '次の周年も一緒に祝いたい' AS text) AS texts
   INNER JOIN (SELECT CONCAT('%', '音楽構造論', '%') AS pattern) AS patterns
           ON texts.text LIKE patterns.pattern
  ) >= 1;
```

サブクエリがあるのでサブクエリから観察すると from 句がないものになってる。こういう SQL がアリなのは知らなかった。
これは文字列の部分一致をしたいだけに見える。

```sql
SELECT * FROM (SELECT '次の音楽構造論の周年も一緒に祝いたい' AS text) AS texts
INNER JOIN (SELECT CONCAT('%', '音楽構造論', '%') AS pattern) AS patterns ON texts.text LIKE patterns.pattern;

+--------------------------------------------------------+-------------------+
| text                                                   | pattern           |
+--------------------------------------------------------+-------------------+
| 次の音楽構造論の周年も一緒に祝いたい                   | %音楽構造論%      |
+--------------------------------------------------------+-------------------+
```

こんな感じで部分一致した場合に true になればいいという考え方だけどこれは明らかに DB でやる必要がない。アプリケーションコードに移動させれば効率化できそう。ちなみに explain だとあまりうまく検出できない。元々 delete の文なので削除ずみの場合は条件を満たすレコードが発見できなくて下記のようになる。

```
EXPLAIN select * from  livecomments WHERE id = '1243' AND livestream_id = '7662' AND (SELECT COUNT(*) FROM (SELECT '次の周年も一緒に祝いたい' AS text) AS texts INNER JOIN (SELECT CONCAT('%', '音楽構造論', '%')AS pattern) AS patterns ON texts.text LIKE patterns.pattern) >= 1;
+----+-------------+-------+------------+------+---------------+------+---------+------+------+----------+-----------------------------------------------------+
| id | select_type | table | partitions | type | possible_keys | key  | key_len | ref  | rows | filtered | Extra                                               |
+----+-------------+-------+------------+------+---------------+------+---------+------+------+----------+-----------------------------------------------------+
|  1 | PRIMARY     | NULL  | NULL       | NULL | NULL          | NULL | NULL    | NULL | NULL |     NULL | Impossible WHERE                                    |
|  2 | SUBQUERY    | NULL  | NULL       | NULL | NULL          | NULL | NULL    | NULL | NULL |     NULL | Impossible WHERE noticed after reading const tables |
|  4 | DERIVED     | NULL  | NULL       | NULL | NULL          | NULL | NULL    | NULL | NULL |     NULL | No tables used                                      |
|  3 | DERIVED     | NULL  | NULL       | NULL | NULL          | NULL | NULL    | NULL | NULL |     NULL | No tables used                                      |
+----+-------------+-------+------------+------+---------------+------+---------+------+------+----------+-----------------------------------------------------+
4 rows in set, 1 warning (0.00 sec)
```

テストコードを書きたいが POST なので注意深くやる必要がありそう、日本語で書いてみる。

1. ライブにひもづくNGワードを全部取得する
2. それぞれのNGワードに対して下記を実行する
   1. あらゆるライブコメントを全件とりだす
   2. 下記の条件を満たすライブコメントを削除する
     - ライブコメントの内容と、NGワードが部分一致する
     - ライブコメントがそのライブに投稿されている

今の実装はかなり効率が悪いのが見える

部分一致は発見が難しいけど、ライブにひもづくライブコメントだけを対象にするのは簡単。
下記の SQL でよさそう。

```sql
- 削除できるか確認
BEGIN;
SELECT * FROM livecomments WHERE livestream_id = 7866;
SELECT * FROM livecomments WHERE livestream_id = 7866 AND livecomments.comment LIKE '%！%';
DELETE FROM livecomments WHERE livestream_id = 7866 AND livecomments.comment LIKE '%！%';
SELECT * FROM livecomments WHERE livestream_id = 7866;

- 戻す
ROLLBACK;
SELECT * FROM livecomments WHERE livestream_id = 7866;
```

mysql2-cs-bind での LIKE 句の書き方がわからないのでプレースホルダーは使わないことにした。

```ruby
tx = $rack.app.new.helpers.db_conn
tx.xquery("SELECT * FROM livecomments WHERE livestream_id = ?", 7866).to_a
tx.xquery("SELECT * FROM livecomments WHERE livestream_id = ? AND livecomments.comment LIKE '%！%'", 7866).to_a
```

これは POST の内容が複雑なのでちょっとテストできない。一回ベンチマーク回してみよう。

## GET '/api/livestream/search' の改善

+-------+-----+------+-------+-----+-----+--------+-------------------------------------------+-------+-------+---------+-------+-------+-------+-------+--------+-----------+------------+--------------+-----------+
| COUNT | 1XX | 2XX  |  3XX  | 4XX | 5XX | METHOD |                    URI                    |  MIN  |  MAX  |   SUM   |  AVG  |  P90  |  P95  |  P99  | STDDEV | MIN(BODY) | MAX(BODY)  |  SUM(BODY)   | AVG(BODY) |
+-------+-----+------+-------+-----+-----+--------+-------------------------------------------+-------+-------+---------+-------+-------+-------+-------+--------+-----------+------------+--------------+-----------+
|  1416 |   0 | 1416 |     0 |   0 |   0 | GET    | ^/api/livestream/search                   | 0.007 | 0.454 | 143.899 | 0.102 | 0.118 | 0.130 | 0.237 |  0.030 | 40427.000 | 155814.000 | 70845586.000 | 50032.194 |
| 40550 |   0 |   63 | 40486 |   1 |   0 | GET    | ^/api/user/.*/icon                        | 0.001 | 0.036 | 114.228 | 0.003 | 0.005 | 0.006 | 0.008 |  0.002 |     0.000 | 171652.000 |  4258921.000 |   105.029 |


1. キーワードとタグ名が一致するタグを取り出す
2. 一致したタグ全てにひもづくストリームタグのストリームIDを取り出す
3. ループ回してストリームを取り出す

この辺りは inner join にするだけでよさそう。

適当にタグ見つけて実験する。

```sql
SELECT livestreams.* FROM tags
 INNER JOIN livestream_tags ON livestream_tags.tag_id = tags.id
 INNER JOIN livestreams ON livestreams.id = livestream_tags.livestream_id
 WHERE tags.name = ?
 ORDER BY livestream_id DESC;
```

```ruby
$rack.get '/api/livestream/search', tag: "釣り"
```

あまりスコアに大きな変化はなかった。alp もクエリダイジェストもあまり変化がない。
反映できてないのかとも思ったがそういうわけではなさそう。
ベンチマークリクエストの中にタグによる検索がどれくらい含まれているのか調べてみよう。
調べてみたら54件しかなかった。であれば効果はあまりないのも仕方がない。

## GET '/api/livestream/search' の改善2

fill_livestream_response のN+1クエリを取り除いてみよう。

タグの取り方を変える

```sql
SELECT tags.* FROM tags
  INNER JOIN livestream_tags ON livestream_tags.tag_id = tags.id
  WHERE livestream_tags.livestream_id = 8754;
```

```ruby
tx = $rack.app.new.helpers.db_conn
livestream_models = tx.xquery('SELECT * FROM livestreams ORDER BY id DESC LIMIT 10').to_a

# 元々の振る舞い
$rack.app.new.helpers.fill_livestream_response(tx, livestream_models.first)
JSON.parse($rack.get('/api/livestream/search?limit=10').body).first

h = $rack.app.new.helpers

def h.fill_livestream_responses(tx, livestream_models)
  ...
end

h.fill_livestream_responses(tx, livestream_models)
```

下記のエラーが出てしまった。

[仕様違反] GET /api/livestream/search へのリクエストに対して、レスポンスボディに必要なフィールドがありません: [0].Owner,[0].Tags,

試してみよう。期待と違う・・・すごいシンプルになってしまってる。

{"id"=>7497,
 "user_id"=>1001,
 "title"=>"jgaMw9mHlKGQHixptnP",
 "description"=>"ehtwgUCVjmT5NUJswgswnkhyxAnyw",
 "playlist_url"=>"https://media.xiii.isucon.dev/api/4/playlist.m3u8",
 "thumbnail_url"=>"https://media.xiii.isucon.dev/isucon12_final.webp",
 "start_at"=>1711929600,
 "end_at"=>1711933200}

修正。さらに tag の集約の仕方を間違ってたので修正。
スコアとしては下がってしまったが search のエンドポイントは大幅に改善したのでこのまま進む。

## GET '/api/livestream/:livestream_id/livecomment' の改善3

いままで作った fill_livecomment_responses を使って N+1 クエリをさらに減らす。


```ruby
JSON.parse($rack.get('/api/livestream/8300/livecomment').body)
```

スコアが少し伸びた。

## GET '/api/livestream/:livestream_id/statistics' の改善

アクセス数は多くないが明らかに遅い。

```
+-------+-----+------+-------+-----+-----+--------+-------------------------------------------+-------+-------+---------+-------+-------+-------+-------+--------+-----------+------------+---------------+-----------+
| COUNT | 1XX | 2XX  |  3XX  | 4XX | 5XX | METHOD |                    URI                    |  MIN  |  MAX  |   SUM   |  AVG  |  P90  |  P95  |  P99  | STDDEV | MIN(BODY) | MAX(BODY)  |   SUM(BODY)   | AVG(BODY) |
+-------+-----+------+-------+-----+-----+--------+-------------------------------------------+-------+-------+---------+-------+-------+-------+-------+--------+-----------+------------+---------------+-----------+
|    34 |   0 |   34 |     0 |   0 |   0 | GET    | ^/api/livestream/.*/statistics            | 0.575 | 4.629 | 136.297 | 4.009 | 4.544 | 4.618 | 4.629 |  0.911 |    78.000 |     83.000 |      2759.000 |    81.147 |
```

```ruby
answer = JSON.parse($rack.get('/api/livestream/8322/statistics').body)
# => {"rank"=>364, "viewers_count"=>1, "max_tip"=>10, "total_reactions"=>8, "total_reports"=>0}
```

アルゴリズム

1. ライブストリームを1つ選ぶ
2. 全てのライブストリームについて下記を行う
   - A: ライブストリームのリアクションの総数を計算
   - B: ライブストリームのチップの総数を計算
   - A+B を点数として決定
3. ライブストリームの点数によってソートし、順位を決める
4. 視聴者数
5. 最大チップ
6. リアクション数
7. スパム報告数
8. 上記をまとめて json 書き出し

ランク計算は非常に遅いのは想像に難くない。せめてgroup by使うようにしてみるか。


```sql
- リアクションの数
SELECT livestreams.id, COUNT(reactions.id) AS point_a FROM livestreams
  INNER JOIN reactions ON reactions.livestream_id = livestreams.id
  GROUP BY livestreams.id;

- チップの数
SELECT livestreams.id, SUM(livecomments.tip) AS point_b FROM livestreams
  INNER JOIN livecomments ON livecomments.livestream_id = livestreams.id
  WHERE livecomments.tip > 0
  GROUP BY livestreams.id;
```

これだけで大きくスコアが改善した。

## GET '/api/user/:username/statistics' の改善

同じ作戦で改善を試みる

```sql
- リアクションの数
SELECT livestreams.user_id, COUNT(reactions.id) AS point_a FROM livestreams
  INNER JOIN reactions ON reactions.livestream_id = livestreams.id
  GROUP BY livestreams.user_id;

- チップの数
SELECT livestreams.user_id, SUM(livecomments.tip) AS point_b FROM livestreams
  INNER JOIN livecomments ON livecomments.livestream_id = livestreams.id
  WHERE livecomments.tip > 0
  GROUP BY livestreams.user_id;
```

これも大きくスコアが改善した。

```
2024-11-13T14:18:38.945Z	info	staff-logger	bench/bench.go:260	ベンチマーク走行時間: 1m0.384146147s
2024-11-13T14:18:38.945Z	info	isupipe-benchmarker	ベンチマーク走行終了
2024-11-13T14:18:38.945Z	info	isupipe-benchmarker	最終チェックを実施します
2024-11-13T14:18:38.945Z	info	isupipe-benchmarker	最終チェックが成功しました
2024-11-13T14:18:38.945Z	info	isupipe-benchmarker	重複排除したログを以下に出力します
2024-11-13T14:18:38.945Z	info	staff-logger	bench/bench.go:277	ベンチエラーを収集します
2024-11-13T14:18:38.946Z	info	staff-logger	bench/bench.go:285	内部エラーを収集します
2024-11-13T14:18:38.946Z	info	staff-logger	bench/bench.go:301	シナリオカウンタを出力します
2024-11-13T14:18:38.946Z	info	isupipe-benchmarker	配信を最後まで視聴できた視聴者数	{"viewers": 669}
2024-11-13T14:18:38.946Z	info	staff-logger	bench/bench.go:323	[シナリオ aggressive-streamer-moderate] 1198 回成功, 35 回失敗
2024-11-13T14:18:38.946Z	info	staff-logger	bench/bench.go:323	[シナリオ dns-watertorture-attack] 991 回成功
2024-11-13T14:18:38.946Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-cold-reserve] 1353 回成功, 106 回失敗
2024-11-13T14:18:38.946Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-moderate] 794 回成功, 25 回失敗
2024-11-13T14:18:38.946Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-report] 56 回成功, 2 回失敗
2024-11-13T14:18:38.946Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-spam] 1210 回成功, 23 回失敗
2024-11-13T14:18:38.946Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer] 669 回成功, 10 回失敗
2024-11-13T14:18:38.946Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ aggressive-streamer-moderate-fail] 35 回失敗
2024-11-13T14:18:38.946Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-cold-reserve-fail] 106 回失敗
2024-11-13T14:18:38.946Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-moderate-fail] 25 回失敗
2024-11-13T14:18:38.946Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-fail] 10 回失敗
2024-11-13T14:18:38.946Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-report-fail] 2 回失敗
2024-11-13T14:18:38.946Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-spam-fail] 23 回失敗
2024-11-13T14:18:38.946Z	info	staff-logger	bench/bench.go:329	DNSAttacker並列数: 15
2024-11-13T14:18:38.946Z	info	staff-logger	bench/bench.go:330	名前解決成功数: 107910
2024-11-13T14:18:38.946Z	info	staff-logger	bench/bench.go:331	名前解決失敗数: 7
2024-11-13T14:18:38.946Z	info	staff-logger	bench/bench.go:335	スコア: 131392
```

## ng_word のインデックス追加

スロークエリの2,5,7位が ng_word に関するものになった。

```sql
SELECT id, user_id, livestream_id, word FROM ng_words WHERE user_id = '1026' AND livestream_id = '7668';
SELECT * FROM ng_words WHERE user_id = '1137' AND livestream_id = '7794' ORDER BY created_at DESC;
SELECT * FROM ng_words WHERE livestream_id = '8030';
```

どれもインデックスがかかってなくフルスキャンになっている。
とりあえず livestream_id でインデックスかけるだけで改善できそう。

```sql
CREATE INDEX livestream_id_index ON ng_words(livestream_id);
```

これを追加した後は、どの SQL にも possible key が入るようになった。

```
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:260	ベンチマーク走行時間: 1m0.416327532s
2024-11-13T14:30:32.224Z	info	isupipe-benchmarker	ベンチマーク走行終了
2024-11-13T14:30:32.224Z	info	isupipe-benchmarker	最終チェックを実施します
2024-11-13T14:30:32.224Z	info	isupipe-benchmarker	最終チェックが成功しました
2024-11-13T14:30:32.224Z	info	isupipe-benchmarker	重複排除したログを以下に出力します
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:277	ベンチエラーを収集します
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:285	内部エラーを収集します
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:301	シナリオカウンタを出力します
2024-11-13T14:30:32.224Z	info	isupipe-benchmarker	配信を最後まで視聴できた視聴者数	{"viewers": 746}
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:323	[シナリオ aggressive-streamer-moderate] 1527 回成功, 19 回失敗
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:323	[シナリオ dns-watertorture-attack] 989 回成功
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-cold-reserve] 1372 回成功, 233 回失敗
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-moderate] 938 回成功, 16 回失敗
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-report] 57 回成功, 1 回失敗
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-spam] 1514 回成功, 32 回失敗
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer] 746 回成功, 1 回失敗
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ aggressive-streamer-moderate-fail] 19 回失敗
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-cold-reserve-fail] 233 回失敗
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-moderate-fail] 16 回失敗
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-fail] 1 回失敗
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-report-fail] 1 回失敗
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-spam-fail] 32 回失敗
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:329	DNSAttacker並列数: 15
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:330	名前解決成功数: 108408
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:331	名前解決失敗数: 0
2024-11-13T14:30:32.224Z	info	staff-logger	bench/bench.go:335	スコア: 146232
```

## POST '/api/livestream/:livestream_id/livecomment' の改善

```
+-------+-----+------+-------+-----+-----+--------+-------------------------------------------+-------+-------+---------+-------+-------+-------+-------+--------+-----------+------------+---------------+-----------+
| COUNT | 1XX | 2XX  |  3XX  | 4XX | 5XX | METHOD |                    URI                    |  MIN  |  MAX  |   SUM   |  AVG  |  P90  |  P95  |  P99  | STDDEV | MIN(BODY) | MAX(BODY)  |   SUM(BODY)   | AVG(BODY) |
+-------+-----+------+-------+-----+-----+--------+-------------------------------------------+-------+-------+---------+-------+-------+-------+-------+--------+-----------+------------+---------------+-----------+
| 81125 |   0 |   99 | 81025 |   1 |   0 | GET    | ^/api/user/.*/icon                        | 0.001 | 0.034 | 216.977 | 0.003 | 0.005 | 0.005 | 0.007 |  0.002 |     0.000 | 171652.000 |   6796557.000 |    83.779 |
|  9406 |   0 | 9404 |     0 |   2 |   0 | POST   | ^/api/livestream/.*/livecomment           | 0.001 | 0.127 | 121.289 | 0.013 | 0.018 | 0.020 | 0.034 |  0.006 |     0.000 |   1733.000 |  14168952.000 |  1506.374 |
|  7871 |   0 | 7870 |     0 |   1 |   0 | POST   | ^/api/livestream/.*/reaction              | 0.001 | 0.146 |  89.746 | 0.011 | 0.016 | 0.018 | 0.027 |  0.005 |     0.000 |   1611.000 |  11544248.000 |  1466.681 |
|  1527 |   0 | 1524 |     0 |   2 |   1 | POST   | /api/register                             | 0.001 | 0.149 |  55.335 | 0.036 | 0.044 | 0.048 | 0.069 |  0.009 |     0.000 | 167260.000 |    821444.000 |   537.946 |
```

アルゴリズム

1. ライブストリームを取り出す
2. ライブストリームにひもづくNGワードを取り出す
3. NGワードごとに、文字列の部分一致を試みる
4. 一致したら失敗

NG ワードの部分一致が SQL になっていて不要な通信コストをかけているのでこれは取り除くことができそう

```
2024-11-13T14:44:42.789Z	info	staff-logger	bench/bench.go:260	ベンチマーク走行時間: 1m0.458042786s
2024-11-13T14:44:42.789Z	info	isupipe-benchmarker	ベンチマーク走行終了
2024-11-13T14:44:42.789Z	info	isupipe-benchmarker	最終チェックを実施します
2024-11-13T14:44:42.789Z	info	isupipe-benchmarker	最終チェックが成功しました
2024-11-13T14:44:42.789Z	info	isupipe-benchmarker	重複排除したログを以下に出力します
2024-11-13T14:44:42.789Z	info	staff-logger	bench/bench.go:277	ベンチエラーを収集します
2024-11-13T14:44:42.789Z	info	staff-logger	bench/bench.go:285	内部エラーを収集します
2024-11-13T14:44:42.789Z	info	staff-logger	bench/bench.go:301	シナリオカウンタを出力します
2024-11-13T14:44:42.789Z	info	isupipe-benchmarker	配信を最後まで視聴できた視聴者数	{"viewers": 767}
2024-11-13T14:44:42.789Z	info	staff-logger	bench/bench.go:323	[シナリオ aggressive-streamer-moderate] 1551 回成功, 27 回失敗
2024-11-13T14:44:42.789Z	info	staff-logger	bench/bench.go:323	[シナリオ dns-watertorture-attack] 993 回成功
2024-11-13T14:44:42.789Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-cold-reserve] 1372 回成功, 183 回失敗
2024-11-13T14:44:42.789Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-moderate] 965 回成功, 19 回失敗
2024-11-13T14:44:42.789Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-report] 56 回成功, 2 回失敗
2024-11-13T14:44:42.789Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-spam] 1552 回成功, 27 回失敗
2024-11-13T14:44:42.789Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer] 767 回成功
2024-11-13T14:44:42.789Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ aggressive-streamer-moderate-fail] 27 回失敗
2024-11-13T14:44:42.789Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-cold-reserve-fail] 183 回失敗
2024-11-13T14:44:42.789Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-moderate-fail] 19 回失敗
2024-11-13T14:44:42.789Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-report-fail] 2 回失敗
2024-11-13T14:44:42.789Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-spam-fail] 27 回失敗
2024-11-13T14:44:42.789Z	info	staff-logger	bench/bench.go:329	DNSAttacker並列数: 15
2024-11-13T14:44:42.789Z	info	staff-logger	bench/bench.go:330	名前解決成功数: 109186
2024-11-13T14:44:42.789Z	info	staff-logger	bench/bench.go:331	名前解決失敗数: 5
2024-11-13T14:44:42.789Z	info	staff-logger	bench/bench.go:335	スコア: 148516
```

## tag に関するN+1クエリの削除

クエリダイジェストをみると tag のシンプルなクエリが大量に実行されているのがわかったので、それらしい箇所を修正した。

```
2024-11-13T14:59:25.100Z	info	staff-logger	bench/bench.go:260	ベンチマーク走行時間: 1m0.348502601s
2024-11-13T14:59:25.100Z	info	isupipe-benchmarker	ベンチマーク走行終了
2024-11-13T14:59:25.100Z	info	isupipe-benchmarker	最終チェックを実施します
2024-11-13T14:59:25.101Z	info	isupipe-benchmarker	最終チェックが成功しました
2024-11-13T14:59:25.101Z	info	isupipe-benchmarker	重複排除したログを以下に出力します
2024-11-13T14:59:25.101Z	info	staff-logger	bench/bench.go:277	ベンチエラーを収集します
2024-11-13T14:59:25.101Z	info	staff-logger	bench/bench.go:285	内部エラーを収集します
2024-11-13T14:59:25.101Z	info	staff-logger	bench/bench.go:301	シナリオカウンタを出力します
2024-11-13T14:59:25.101Z	info	isupipe-benchmarker	配信を最後まで視聴できた視聴者数	{"viewers": 789}
2024-11-13T14:59:25.101Z	info	staff-logger	bench/bench.go:323	[シナリオ aggressive-streamer-moderate] 1602 回成功, 27 回失敗
2024-11-13T14:59:25.101Z	info	staff-logger	bench/bench.go:323	[シナリオ dns-watertorture-attack] 1032 回成功
2024-11-13T14:59:25.101Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-cold-reserve] 1372 回成功, 312 回失敗
2024-11-13T14:59:25.101Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-moderate] 1006 回成功, 13 回失敗
2024-11-13T14:59:25.101Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-report] 56 回成功, 2 回失敗
2024-11-13T14:59:25.101Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-spam] 1595 回成功, 36 回失敗
2024-11-13T14:59:25.101Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer] 789 回成功
2024-11-13T14:59:25.101Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ aggressive-streamer-moderate-fail] 27 回失敗
2024-11-13T14:59:25.101Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-cold-reserve-fail] 312 回失敗
2024-11-13T14:59:25.101Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-moderate-fail] 13 回失敗
2024-11-13T14:59:25.101Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-report-fail] 2 回失敗
2024-11-13T14:59:25.101Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-spam-fail] 36 回失敗
2024-11-13T14:59:25.101Z	info	staff-logger	bench/bench.go:329	DNSAttacker並列数: 15
2024-11-13T14:59:25.101Z	info	staff-logger	bench/bench.go:330	名前解決成功数: 113607
2024-11-13T14:59:25.101Z	info	staff-logger	bench/bench.go:331	名前解決失敗数: 2
2024-11-13T14:59:25.101Z	info	staff-logger	bench/bench.go:335	スコア: 155391
```

## トランザクションの削除

クエリダイジェストで COMMIT が全体の 58% も消費しているので、明らかに不要なトランザクションを削除した。
少し改善効果があった。

```
2024-11-13T15:14:32.101Z	info	staff-logger	bench/bench.go:260	ベンチマーク走行時間: 1m0.345773645s
2024-11-13T15:14:32.101Z	info	isupipe-benchmarker	ベンチマーク走行終了
2024-11-13T15:14:32.101Z	info	isupipe-benchmarker	最終チェックを実施します
2024-11-13T15:14:32.101Z	info	isupipe-benchmarker	最終チェックが成功しました
2024-11-13T15:14:32.101Z	info	isupipe-benchmarker	重複排除したログを以下に出力します
2024-11-13T15:14:32.101Z	info	staff-logger	bench/bench.go:277	ベンチエラーを収集します
2024-11-13T15:14:32.101Z	info	staff-logger	bench/bench.go:285	内部エラーを収集します
2024-11-13T15:14:32.101Z	info	staff-logger	bench/bench.go:301	シナリオカウンタを出力します
2024-11-13T15:14:32.101Z	info	isupipe-benchmarker	配信を最後まで視聴できた視聴者数	{"viewers": 828}
2024-11-13T15:14:32.101Z	info	staff-logger	bench/bench.go:323	[シナリオ aggressive-streamer-moderate] 1597 回成功, 33 回失敗
2024-11-13T15:14:32.101Z	info	staff-logger	bench/bench.go:323	[シナリオ dns-watertorture-attack] 1066 回成功
2024-11-13T15:14:32.101Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-cold-reserve] 1372 回成功, 313 回失敗
2024-11-13T15:14:32.101Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-moderate] 1008 回成功, 23 回失敗
2024-11-13T15:14:32.101Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-report] 56 回成功, 2 回失敗
2024-11-13T15:14:32.101Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-spam] 1609 回成功, 23 回失敗
2024-11-13T15:14:32.101Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer] 828 回成功
2024-11-13T15:14:32.101Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ aggressive-streamer-moderate-fail] 33 回失敗
2024-11-13T15:14:32.101Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-cold-reserve-fail] 313 回失敗
2024-11-13T15:14:32.101Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-moderate-fail] 23 回失敗
2024-11-13T15:14:32.101Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-report-fail] 2 回失敗
2024-11-13T15:14:32.101Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-spam-fail] 23 回失敗
2024-11-13T15:14:32.101Z	info	staff-logger	bench/bench.go:329	DNSAttacker並列数: 15
2024-11-13T15:14:32.101Z	info	staff-logger	bench/bench.go:330	名前解決成功数: 117234
2024-11-13T15:14:32.101Z	info	staff-logger	bench/bench.go:331	名前解決失敗数: 1
2024-11-13T15:14:32.101Z	info	staff-logger	bench/bench.go:335	スコア: 161842
```

まだ COMMIT が支配的なので、トランザクションを積極的に削ってみることにした。
そこまで大きな効果はなかった。 icon のインサートが重いのではないかと思った。

## pdns のログを観察

クエリダイジェストで、ほとんどが DNS のクエリとなっており、かつ件数が 30 万以上の回数となっている。
これはどうやら DNS 水責めによるものではないかと考えた。

journalctl -u pdns -n1000

ログを見るとめちゃめちゃな文字列が入っていたりする。

```
Nov 14 00:32:36 isucon13 pdns_server[366]: Remote 127.0.0.1 wants 'pipe.u.isucon.local|A', do = 0, bufsize = 512
Nov 14 00:32:36 isucon13 pdns_server[366]: Remote 127.0.0.1 wants 'oj0t0tphnn5rehiuhozv8avap5kcd0q0.u.isucon.local|A', do = 0, bufsize =>
Nov 14 00:32:36 isucon13 pdns_server[366]: Remote 127.0.0.1 wants '5bjafwrwd06e9yeq5e2gytzbgh0.u.isucon.local|A', do = 0, bufsize = 512
Nov 14 00:32:36 isucon13 pdns_server[366]: Remote 127.0.0.1 wants '1a6rxst9qn4qxhfn9m0.u.isucon.local|A', do = 0, bufsize = 512
Nov 14 00:32:36 isucon13 pdns_server[366]: Remote 127.0.0.1 wants 'kvh9ly1n5x2dfk2olp00vs0.u.isucon.local|A', do = 0, bufsize = 512
Nov 14 00:32:36 isucon13 pdns_server[366]: Remote 127.0.0.1 wants 'lic7oviu5xb9i5502g45l4rtquzf50.u.isucon.local|A', do = 0, bufsize = 5>
Nov 14 00:32:36 isucon13 pdns_server[366]: Remote 127.0.0.1 wants 'ylkhlpvotog6ocmyw230.u.isucon.local|A', do = 0, bufsize = 512
Nov 14 00:32:36 isucon13 pdns_server[366]: Remote 127.0.0.1 wants 'iokvb46w9vzud6hw3me6q109csm0.u.isucon.local|A', do = 0, bufsize = 512
```

これをどうにか無視するようにしたい。
ベンチマークが1箇所なので攻撃元は 127.0.0.1 しかない。
これはちょっと対策がわからないので講評を見てみよう。

# 5️⃣ 講評を見ながらさらに改善を試みる

https://isucon.net/archives/58001272.html

- 初期実装では各DNSレコードのTTLが 0 で設定されているので、数値を大きくし名前解決結果をベンチマーク側でキャッシュさせる
- PowerDNSのキャッシュ機能を有効にする
- データベースに不足しているインデックスを付与する
- アプリケーションのデータベースと分離する
- DNSサーバを実装し、ユーザ名がDBになければゆっくりレスポンスをする、あるいはレスポンスをしない
- dnsdist を導入し、NXDOMAIN(名前が見つからない場合)にゆっくりレスポンスをする、あるいはレスポンスをしないフィルタを導入する

## powerDNS の TTL を増やす

cat /etc/powerdns/pdns.conf

```
api=yes
api-key=isudns
webserver=yes
include-dir=/etc/powerdns/pdns.d
launch=gmysql
gmysql-port=3306
gmysql-user=isudns
gmysql-dbname=isudns
gmysql-password=isudns
local-port=53
security-poll-suffix=
setgid=pdns
setuid=pdns
cache-ttl=0
negquery-cache-ttl=0
query-cache-ttl=0
zone-cache-refresh-interval=0
zone-metadata-cache-ttl=0

log-dns-queries=yes
loglevel=7
log-dns-details=yes
```

それぞれの ttl を 3600 にしてみる。

sudo systemctl restart pdns

クエリダイジェストで DNS 水責めの痕跡が少し和らいで、スコアが改善した。

```
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:260	ベンチマーク走行時間: 1m0.116377702s
2024-11-13T15:52:52.881Z	info	isupipe-benchmarker	ベンチマーク走行終了
2024-11-13T15:52:52.881Z	info	isupipe-benchmarker	最終チェックを実施します
2024-11-13T15:52:52.881Z	info	isupipe-benchmarker	最終チェックが成功しました
2024-11-13T15:52:52.881Z	info	isupipe-benchmarker	重複排除したログを以下に出力します
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:277	ベンチエラーを収集します
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:285	内部エラーを収集します
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:301	シナリオカウンタを出力します
2024-11-13T15:52:52.881Z	info	isupipe-benchmarker	配信を最後まで視聴できた視聴者数	{"viewers": 868}
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:323	[シナリオ aggressive-streamer-moderate] 1817 回成功, 38 回失敗
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:323	[シナリオ dns-watertorture-attack] 1814 回成功
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-cold-reserve] 1372 回成功, 780 回失敗
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-moderate] 1228 回成功, 20 回失敗
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-report] 57 回成功, 1 回失敗
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-spam] 1818 回成功, 38 回失敗
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer] 868 回成功, 4 回失敗
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ aggressive-streamer-moderate-fail] 38 回失敗
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-cold-reserve-fail] 780 回失敗
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-moderate-fail] 20 回失敗
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-fail] 4 回失敗
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-report-fail] 1 回失敗
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-spam-fail] 38 回失敗
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:329	DNSAttacker並列数: 15
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:330	名前解決成功数: 183261
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:331	名前解決失敗数: 18
2024-11-13T15:52:52.881Z	info	staff-logger	bench/bench.go:335	スコア: 166487
```

DNS サーバー実装するのは無理だなぁ。後は nginx, mysql, sinatra のログ切って終了でいいかな。

## ログを無効化する

```
2024-11-13T16:06:19.595Z	info	staff-logger	bench/bench.go:260	ベンチマーク走行時間: 1m0.961817196s
2024-11-13T16:06:19.595Z	info	isupipe-benchmarker	ベンチマーク走行終了
2024-11-13T16:06:19.595Z	info	isupipe-benchmarker	最終チェックを実施します
2024-11-13T16:06:19.595Z	info	isupipe-benchmarker	最終チェックが成功しました
2024-11-13T16:06:19.596Z	info	isupipe-benchmarker	重複排除したログを以下に出力します
2024-11-13T16:06:19.596Z	info	staff-logger	bench/bench.go:277	ベンチエラーを収集します
2024-11-13T16:06:19.596Z	info	staff-logger	bench/bench.go:285	内部エラーを収集します
2024-11-13T16:06:19.596Z	info	staff-logger	bench/bench.go:301	シナリオカウンタを出力します
2024-11-13T16:06:19.596Z	info	isupipe-benchmarker	配信を最後まで視聴できた視聴者数	{"viewers": 936}
2024-11-13T16:06:19.596Z	info	staff-logger	bench/bench.go:323	[シナリオ aggressive-streamer-moderate] 2002 回成功, 29 回失敗
2024-11-13T16:06:19.596Z	info	staff-logger	bench/bench.go:323	[シナリオ dns-watertorture-attack] 1781 回成功
2024-11-13T16:06:19.596Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-cold-reserve] 1372 回成功, 1154 回失敗
2024-11-13T16:06:19.596Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-moderate] 1244 回成功, 20 回失敗
2024-11-13T16:06:19.596Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-report] 58 回成功, 1 回失敗
2024-11-13T16:06:19.596Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-spam] 1996 回成功, 36 回失敗
2024-11-13T16:06:19.596Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer] 936 回成功
2024-11-13T16:06:19.596Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ aggressive-streamer-moderate-fail] 29 回失敗
2024-11-13T16:06:19.596Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-cold-reserve-fail] 1154 回失敗
2024-11-13T16:06:19.596Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-moderate-fail] 20 回失敗
2024-11-13T16:06:19.596Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-report-fail] 1 回失敗
2024-11-13T16:06:19.596Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-spam-fail] 36 回失敗
2024-11-13T16:06:19.596Z	info	staff-logger	bench/bench.go:329	DNSAttacker並列数: 15
2024-11-13T16:06:19.596Z	info	staff-logger	bench/bench.go:330	名前解決成功数: 186493
2024-11-13T16:06:19.596Z	info	staff-logger	bench/bench.go:331	名前解決失敗数: 0
2024-11-13T16:06:19.596Z	info	staff-logger	bench/bench.go:335	スコア: 181700
```

powerdns のログも切ってみるか。ほんの少しスコアが増えた。

```
2024-11-13T16:09:47.358Z	info	staff-logger	bench/bench.go:260	ベンチマーク走行時間: 1m0.933701326s
2024-11-13T16:09:47.358Z	info	staff-logger	bench/bench.go:277	ベンチエラーを収集します
2024-11-13T16:09:47.358Z	info	staff-logger	bench/bench.go:285	内部エラーを収集します
2024-11-13T16:09:47.358Z	info	staff-logger	bench/bench.go:301	シナリオカウンタを出力します
2024-11-13T16:09:47.358Z	info	staff-logger	bench/bench.go:323	[シナリオ aggressive-streamer-moderate] 2013 回成功, 32 回失敗
2024-11-13T16:09:47.358Z	info	staff-logger	bench/bench.go:323	[シナリオ dns-watertorture-attack] 1789 回成功
2024-11-13T16:09:47.358Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-cold-reserve] 1372 回成功, 1198 回失敗
2024-11-13T16:09:47.358Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-moderate] 1327 回成功, 20 回失敗
2024-11-13T16:09:47.358Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-report] 58 回成功, 1 回失敗
2024-11-13T16:09:47.358Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-spam] 2003 回成功, 44 回失敗
2024-11-13T16:09:47.358Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer] 941 回成功
2024-11-13T16:09:47.358Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ aggressive-streamer-moderate-fail] 32 回失敗
2024-11-13T16:09:47.358Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-cold-reserve-fail] 1198 回失敗
2024-11-13T16:09:47.358Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-moderate-fail] 20 回失敗
2024-11-13T16:09:47.358Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-report-fail] 1 回失敗
2024-11-13T16:09:47.358Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-spam-fail] 44 回失敗
2024-11-13T16:09:47.359Z	info	staff-logger	bench/bench.go:329	DNSAttacker並列数: 15
2024-11-13T16:09:47.359Z	info	staff-logger	bench/bench.go:330	名前解決成功数: 187414
2024-11-13T16:09:47.359Z	info	staff-logger	bench/bench.go:331	名前解決失敗数: 1
2024-11-13T16:09:47.359Z	info	staff-logger	bench/bench.go:335	スコア: 183007
```

やれてないこととしては、サーバ分ける練習ができてないんだけれど
データベースの構成とかがわかってれば本当は難しくないはず。
前回うまくいかなかったのは DNS サーバー考慮できてなかったからじゃないかなぁ。

## icons を全てメモリに載せる

ふと思いついて icons を全て memcached に載せて mysql をやめたらスコアが上がった。

```
2024-11-14T01:36:59.183Z	info	staff-logger	bench/bench.go:260	ベンチマーク走行時間: 1m0.809573607s
2024-11-14T01:36:59.183Z	info	isupipe-benchmarker	ベンチマーク走行終了
2024-11-14T01:36:59.183Z	info	isupipe-benchmarker	最終チェックを実施します
2024-11-14T01:36:59.183Z	info	isupipe-benchmarker	最終チェックが成功しました
2024-11-14T01:36:59.183Z	info	isupipe-benchmarker	重複排除したログを以下に出力します
2024-11-14T01:36:59.183Z	info	staff-logger	bench/bench.go:277	ベンチエラーを収集します
2024-11-14T01:36:59.184Z	info	staff-logger	bench/bench.go:285	内部エラーを収集します
2024-11-14T01:36:59.184Z	info	staff-logger	bench/bench.go:301	シナリオカウンタを出力します
2024-11-14T01:36:59.184Z	info	isupipe-benchmarker	配信を最後まで視聴できた視聴者数	{"viewers": 987}
2024-11-14T01:36:59.184Z	info	staff-logger	bench/bench.go:323	[シナリオ aggressive-streamer-moderate] 2381 回成功, 28 回失敗
2024-11-14T01:36:59.184Z	info	staff-logger	bench/bench.go:323	[シナリオ dns-watertorture-attack] 1850 回成功
2024-11-14T01:36:59.184Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-cold-reserve] 1372 回成功, 1576 回失敗
2024-11-14T01:36:59.184Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-moderate] 1538 回成功, 12 回失敗
2024-11-14T01:36:59.184Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-report] 58 回成功, 1 回失敗
2024-11-14T01:36:59.184Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-spam] 2348 回成功, 61 回失敗
2024-11-14T01:36:59.184Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer] 987 回成功, 10 回失敗
2024-11-14T01:36:59.184Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ aggressive-streamer-moderate-fail] 28 回失敗
2024-11-14T01:36:59.184Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-cold-reserve-fail] 1576 回失敗
2024-11-14T01:36:59.184Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-moderate-fail] 12 回失敗
2024-11-14T01:36:59.184Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-fail] 10 回失敗
2024-11-14T01:36:59.184Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-report-fail] 1 回失敗
2024-11-14T01:36:59.184Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-spam-fail] 61 回失敗
2024-11-14T01:36:59.184Z	info	staff-logger	bench/bench.go:329	DNSAttacker並列数: 15
2024-11-14T01:36:59.184Z	info	staff-logger	bench/bench.go:330	名前解決成功数: 189881
2024-11-14T01:36:59.184Z	info	staff-logger	bench/bench.go:331	名前解決失敗数: 1
2024-11-14T01:36:59.184Z	info	staff-logger	bench/bench.go:335	スコア: 195727
```

意外と簡単だったけど3台構成にする場合は注意が必要かもしれない。
TTL を80秒に設定してベンチマーク2回目の時に落ちないようにする。
この変更後も COMMIT が一番コストが高い。

```
# Profile
# Rank Query ID                     Response time  Calls  R/Call V/M   Ite
# ==== ============================ ============== ====== ====== ===== ===
#    1 0xFFFCA4D67EA0A788813031B... 190.9241 60.8%  37381 0.0051  0.00 COMMIT
```

あ、でも initialize の時にこれを実行してるのかもしれないし、そんなに気にしなくていいんじゃないか。

## user も全てメモリに載せられないか

一応データ量を確認する

```sql
SELECT
    table_schema AS 'Database',
    table_name AS 'Table',
    ROUND(data_length / 1024 / 1024, 2) AS 'Data Size (MB)',
    ROUND(index_length / 1024 / 1024, 2) AS 'Index Size (MB)',
    ROUND((data_length + index_length) / 1024 / 1024, 2) AS 'Total Size (MB)'
FROM
    information_schema.TABLES
WHERE
    table_schema = 'isupipe'
ORDER BY
    (data_length + index_length) DESC;
```

```
+----------+----------------------------+----------------+-----------------+-----------------+
| Database | Table                      | Data Size (MB) | Index Size (MB) | Total Size (MB) |
+----------+----------------------------+----------------+-----------------+-----------------+
| isupipe  | ng_words                   |           1.52 |            3.03 |            4.55 |
| isupipe  | livestreams                |           3.52 |            0.30 |            3.81 |
| isupipe  | livecomments               |           2.52 |            0.48 |            3.00 |
| isupipe  | reactions                  |           1.52 |            0.42 |            1.94 |
| isupipe  | livestream_tags            |           1.52 |            0.38 |            1.89 |
| isupipe  | users                      |           1.52 |            0.14 |            1.66 |
| isupipe  | reservation_slots          |           0.48 |            0.28 |            0.77 |
| isupipe  | themes                     |           0.14 |            0.09 |            0.23 |
| isupipe  | icons                      |           0.02 |            0.02 |            0.03 |
| isupipe  | tags                       |           0.02 |            0.02 |            0.03 |
| isupipe  | livecomment_reports        |           0.02 |            0.00 |            0.02 |
| isupipe  | livestream_viewers_history |           0.02 |            0.00 |            0.02 |
+----------+----------------------------+----------------+-----------------+-----------------+
```

メモリは5Gあって余ってるからありな気がする。やってみようか。
あまり効果はなかったので反映しないことにした。
user のオブジェクト丸ごと格納するようなキャッシュの仕方ではほとんど効果がないようだ。

## dnsdist を入れてみる

まずは pdns のポートを 5300 にかえる

sudo vim /etc/powerdns/pdns.conf
sudo systemctl restart pdns

dnsdist を設定する

sudo apt install dnsdist
sudo vim /etc/dnsdist/dnsdist.conf

```
newServer({address="127.0.0.1:5300"})
```

sudo systemctl start dnsdist
sudo systemctl enable dnsdist

名前解決ができるか確認する

```
dig isato4.u.isucon.local @127.0.0.1
```

status: NOERROR で問題なさそう。わざと変な名前解決できないものを送る。

```
dig hogehogeisato4.u.isucon.local @127.0.0.1
```

status: NXDOMAIN となった。
下記でドロップさせれるらしいので設定に追加。
ChatGPT や下記のサイトを参考にした。
https://kazeburo.hatenablog.com/entry/2023/12/02/235258


```
addResponseAction(
  RCodeRule(DNSRCode.NXDOMAIN),
  DelayResponseAction(3000)
)
```

ダメだった。どう直すかもよくわからないので別の記事を参考にしてみる。
確かに遅延が入るようになった。大きくスコアが改善。

```
2024-11-14T12:32:50.707Z	info	staff-logger	bench/bench.go:260	ベンチマーク走行時間: 1m0.883861838s
2024-11-14T12:32:50.707Z	info	isupipe-benchmarker	ベンチマーク走行終了
2024-11-14T12:32:50.707Z	info	isupipe-benchmarker	最終チェックを実施します
2024-11-14T12:32:50.707Z	info	isupipe-benchmarker	最終チェックが成功しました
2024-11-14T12:32:50.707Z	info	isupipe-benchmarker	重複排除したログを以下に出力します
2024-11-14T12:32:50.707Z	info	staff-logger	bench/bench.go:277	ベンチエラーを収集します
2024-11-14T12:32:50.709Z	info	staff-logger	bench/bench.go:285	内部エラーを収集します
2024-11-14T12:32:50.709Z	info	staff-logger	bench/bench.go:301	シナリオカウンタを出力します
2024-11-14T12:32:50.709Z	info	isupipe-benchmarker	配信を最後まで視聴できた視聴者数	{"viewers": 1079}
2024-11-14T12:32:50.709Z	info	staff-logger	bench/bench.go:323	[シナリオ aggressive-streamer-moderate] 2524 回成功, 29 回失敗
2024-11-14T12:32:50.710Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-cold-reserve] 1372 回成功, 1764 回失敗
2024-11-14T12:32:50.710Z	info	staff-logger	bench/bench.go:323	[シナリオ streamer-moderate] 1652 回成功, 29 回失敗
2024-11-14T12:32:50.710Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-report] 58 回成功, 1 回失敗
2024-11-14T12:32:50.710Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer-spam] 2489 回成功, 66 回失敗
2024-11-14T12:32:50.710Z	info	staff-logger	bench/bench.go:323	[シナリオ viewer] 1079 回成功
2024-11-14T12:32:50.710Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ aggressive-streamer-moderate-fail] 29 回失敗
2024-11-14T12:32:50.710Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-cold-reserve-fail] 1764 回失敗
2024-11-14T12:32:50.710Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ streamer-moderate-fail] 29 回失敗
2024-11-14T12:32:50.710Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-report-fail] 1 回失敗
2024-11-14T12:32:50.710Z	info	staff-logger	bench/bench.go:323	[失敗シナリオ viewer-spam-fail] 66 回失敗
2024-11-14T12:32:50.710Z	info	staff-logger	bench/bench.go:329	DNSAttacker並列数: 9
2024-11-14T12:32:50.710Z	info	staff-logger	bench/bench.go:330	名前解決成功数: 14838
2024-11-14T12:32:50.710Z	info	staff-logger	bench/bench.go:331	名前解決失敗数: 121
2024-11-14T12:32:50.710Z	info	staff-logger	bench/bench.go:335	スコア: 208231
```

## やらなかったこと

nginx-puma も puma-mysql も TCP 接続を前提に作っているけど unix ソケットにすると高速化する可能性があった。
その場合は複数台構成にはできなくなるけど仮想マシン上で高いスコアを出すならやってみてもよかったかもしれない。

tag は新規追加も更新もできないので定数化するという手段もあったらしい。
結構 INNER JOIN で書き直してしまっているので今更それをやるのはちょっとしんどいかなぁ。

JSON シリアライザを oj に変えると早くなるという話もあった。
ただ、ここ数年でデフォルトライブラリもかなり高速化されたらしく oj を使っても対してスコアが変わらなかった。

画像の配信で使っている send_file を使うよりは nginx でファイル配信をした方が早いらしい。
そういう作戦で行くならアップロードされたファイルは public/api/user/xxxxxx/icon というディレクトリに配置して
nginx でそのまま配信できるようにしたら性能が上がったかもしれない。
ただ今回は 304 を返すのに特別なヘッダーを使った実装をしてるからそこまでやっても効果は出ないだろう。

estackprof を入れてみたが、どうも期待した動作をしてなかったのですぐ消した。
そもそも stackprof が middleware 対応してるので継続的にメンテナンスされてるそっちの方をインストールした方がよさそう。

# 6️⃣ mysql 専用サーバに隔離する

ISUCON ではインストール済みだけど、とりあえず自前で入れてみる。

```sh
# インストール
sudo apt install mysql-server-8.0
sudo systemctl start mysql.service
sudo systemctl enable mysql.service

# ログインできることを確認
sudo mysql
```

isucon ユーザを作り TCP 接続を許可する

```sql
CREATE DATABASE IF NOT EXISTS `isupipe`;
CREATE USER isucon IDENTIFIED BY 'isucon';
GRANT ALL PRIVILEGES ON isupipe.* TO 'isucon'@'%';
ALTER USER 'isucon'@'%' IDENTIFIED BY 'isucon';
```

これで TCP で入れるようになった。

```
mysql -uisucon -pisucon isupipe
```

と思ったら まだ localhost からの接続しか許可してないので外からはさわれない。

```
sudo ss -tuln | grep 3306
tcp   LISTEN 0      151              127.0.0.1:3306       0.0.0.0:*
tcp   LISTEN 0      70               127.0.0.1:33060      0.0.0.0:*
```

/etc/mysql/mysql.conf.d/mysqld.cnf をいじる。

```
bind-address = 0.0.0.0
```

セキュリティ大丈夫かと思ったけど、この bind-address は一個しか指定できないのでユーザごとのホスト制限を使うのがいいようだ。
Sequel Ace でもアクセスできるのを確認する。

| key      | value                |
|----------|----------------------|
| user     | isucon               |
| password | isucon               |
| host     | isucon13v2.orb.local |

OK。isucon13 から isucon13v2 のテーブルを初期化してみよう。
env.sh を開いて、ユーザ名やパスワードは揃えてるので下記の行だけ変更。

```
ISUCON13_MYSQL_DIALCONFIG_ADDRESS="isucon13v2.orb.local"
```

ベンチマークを走らせてみた。あっさり成功。

# アプリケーションサーバーを分ける

今の構成を確認してみる。
isupipe-ruby は 8080 でアクセス受け付けるようになってる。

```
ExecStart=/home/isucon/.x bundle exec puma --bind tcp://0.0.0.0:8080 --workers 8 --threads 0:8 --environment production
```

実際、nginx を停止させて下記のコマンドを叩くと結果が得られる。

curl http://localhost:8080/api/tag

ポートを確認してみる。

```
ss -tuln | grep 8080

tcp   LISTEN 0      1024              0.0.0.0:8080       0.0.0.0:*
```

となっているので、外から触れるっぽい。ホストOS から実行してみたらちゃんと動いた。

```
curl http://isucon13.orb.local:8080/api/tag
```

なのでサーバー構成としては下記のような感じがよさそう

1. nginx + puma
2. mysql
3. memcached + puma

nginx は下記のプロキシで http(s) のリクエストを 8080 に誘導するようになってる。

```
  location /api {
    proxy_set_header Host $host;
    proxy_pass http://localhost:8080;
  }
```

うーんしかし、本当はソケット接続の方がいいのかな。
