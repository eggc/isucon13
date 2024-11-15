# frozen_string_literal: true

require 'base64'
require 'bcrypt'
require 'digest'
require 'mysql2'
require 'mysql2-cs-bind'
require 'open3'
require 'securerandom'
require 'sinatra/base'
require 'sinatra/json'
require 'dalli'

module Isupipe
  class App < Sinatra::Base
    set :show_exceptions, :after_handler
    set :sessions, domain: 'u.isucon.local', path: '/', expire_after: 1000*60
    set :session_secret, ENV.fetch('ISUCON13_SESSION_SECRETKEY', 'isucon13_session_cookiestore_defaultsecret').unpack('H*')[0]

    POWERDNS_SUBDOMAIN_ADDRESS = ENV.fetch('ISUCON13_POWERDNS_SUBDOMAIN_ADDRESS')

    DEFAULT_SESSION_ID_KEY = 'SESSIONID'
    DEFAULT_SESSION_EXPIRES_KEY = 'EXPIRES'
    DEFAULT_USER_ID_KEY = 'USERID'
    DEFAULT_USERNAME_KEY = 'USERNAME'

    class HttpError < StandardError
      attr_reader :code

      def initialize(code, message = nil)
        super(message || "HTTP error #{code}")
        @code = code
      end
    end

    error HttpError do
      e = env['sinatra.error']
      status e.code
      json(error: e.message)
    end

    helpers do
      def dc
        Thread.current[:dc] ||= Dalli::Client.new('localhost', { expires_in: 80 })
      end

      def db_conn
        Thread.current[:db_conn] ||= connect_db
      end

      def connect_db
        Mysql2::Client.new(
          host: ENV.fetch('ISUCON13_MYSQL_DIALCONFIG_ADDRESS', '127.0.0.1'),
          port: ENV.fetch('ISUCON13_MYSQL_DIALCONFIG_PORT', '3306').to_i,
          username: ENV.fetch('ISUCON13_MYSQL_DIALCONFIG_USER', 'isucon'),
          password: ENV.fetch('ISUCON13_MYSQL_DIALCONFIG_PASSWORD', 'isucon'),
          database: ENV.fetch('ISUCON13_MYSQL_DIALCONFIG_DATABASE', 'isupipe'),
          symbolize_keys: true,
          cast_booleans: true,
          reconnect: true,
        )
      end

      def db_transaction(&block)
        db_conn.query('BEGIN')
        ok = false
        begin
          retval = block.call(db_conn)
          db_conn.query('COMMIT')
          ok = true
          retval
        ensure
          unless ok
            db_conn.query('ROLLBACK')
          end
        end
      end

      def decode_request_body(data_class)
        body = JSON.parse(request.body.tap(&:rewind).read, symbolize_names: true)
        data_class.new(**data_class.members.map { |key| [key, body[key]] }.to_h)
      end

      def cast_as_integer(str)
        Integer(str, 10)
      rescue
        raise HttpError.new(400)
      end

      def verify_user_session!
        sess = session[DEFAULT_SESSION_ID_KEY]
        unless sess
          raise HttpError.new(403)
        end

        session_expires = sess[DEFAULT_SESSION_EXPIRES_KEY]
        unless session_expires
          raise HttpError.new(403)
        end

        now = Time.now
        if now.to_i > session_expires
          raise HttpError.new(401, 'session has expired')
        end

        nil
      end

      def fill_livestream_responses(tx, livestream_models)
        return [] if livestream_models.size == 0

        user_ids = livestream_models.map { _1[:user_id] }.join(",")
        owner_models = tx.xquery("SELECT * FROM users WHERE id IN (#{user_ids})")
        owners = fill_user_responses(tx, owner_models, with_theme: false).to_h do
          [_1[:id], _1]
        end

        livestream_ids = livestream_models.map { _1[:id] }.join(",")
        tag_models = tx.xquery(<<-SQL)
          SELECT livestream_id, tags.* FROM tags
            INNER JOIN livestream_tags ON livestream_tags.tag_id = tags.id
            WHERE livestream_tags.livestream_id IN(#{livestream_ids});
        SQL
        tags = tag_models.group_by { _1[:livestream_id] }
        tags.transform_values! { |value| value.map { |hash| hash.slice(:id, :name) } }

        livestream_models.map do |livestream_model|
          livestream_id = livestream_model[:id]
          user_id = livestream_model[:user_id]

          livestream_model.slice(:id, :title, :description, :playlist_url, :thumbnail_url, :start_at, :end_at).merge(
            owner: owners[user_id],
            tags: tags[livestream_id] || [],
          )
        end
      end

      def fill_livestream_response(tx, livestream_model)
        owner_model = tx.xquery('SELECT * FROM users WHERE id = ?', livestream_model.fetch(:user_id)).first
        owner = fill_user_response(tx, owner_model)

        tag_models = tx.xquery(<<-SQL, livestream_model[:id])
          SELECT tags.* FROM tags
            INNER JOIN livestream_tags ON livestream_tags.tag_id = tags.id
            WHERE livestream_tags.livestream_id = ?;
        SQL
        tags = tag_models.map do |tag_model|
          {
            id: tag_model.fetch(:id),
            name: tag_model.fetch(:name),
          }
        end

        livestream_model.slice(:id, :title, :description, :playlist_url, :thumbnail_url, :start_at, :end_at).merge(
          owner:,
          tags:,
        )
      end

      def fill_livecomment_responses(tx, livecomment_models)
        return [] if livecomment_models.size == 0

        user_ids = livecomment_models.map { _1[:user_id] }.join(",")
        comment_owner_models = tx.xquery("SELECT * FROM users WHERE id IN (#{user_ids})")
        comment_owners = fill_user_responses(tx, comment_owner_models, with_theme: false).to_h do
          [_1[:id], _1]
        end

        livestream_ids = livecomment_models.map { _1[:livestream_id] }.join(",")
        livestream_models = tx.xquery("SELECT * FROM livestreams WHERE id IN(#{livestream_ids})")
        livestreams = fill_livestream_responses(tx, livestream_models).to_h do
          [_1[:id], _1]
        end

        livecomment_models.map do |livecomment_model|
          livecomment_model.slice(:id, :comment, :tip, :created_at).merge(
            user: comment_owners[livecomment_model[:user_id]],
            livestream: livestreams[livecomment_model[:livestream_id]],
          )
        end
      end

      def fill_livecomment_response(tx, livecomment_model)
        comment_owner_model = tx.xquery('SELECT * FROM users WHERE id = ?', livecomment_model.fetch(:user_id)).first
        comment_owner = fill_user_response(tx, comment_owner_model, with_theme: false)

        livestream_model = tx.xquery('SELECT * FROM livestreams WHERE id = ?', livecomment_model.fetch(:livestream_id)).first
        livestream = fill_livestream_response(tx, livestream_model)

        livecomment_model.slice(:id, :comment, :tip, :created_at).merge(
          user: comment_owner,
          livestream:,
        )
      end

      def fill_livecomment_report_response(tx, report_model)
        reporter_model = tx.xquery('SELECT * FROM users WHERE id = ?', report_model.fetch(:user_id)).first
        reporter = fill_user_response(tx, reporter_model)

        livecomment_model = tx.xquery('SELECT * FROM livecomments WHERE id = ?', report_model.fetch(:livecomment_id)).first
        livecomment = fill_livecomment_response(tx, livecomment_model)

        report_model.slice(:id, :created_at).merge(
          reporter:,
          livecomment:,
        )
      end

      def fill_reaction_responses(tx, reaction_models)
        return [] if reaction_models.size == 0

        user_ids = reaction_models.map { _1[:user_id] }.join(',')
        user_models = tx.xquery("SELECT * FROM users WHERE id IN (#{user_ids})")
        users = fill_user_responses(tx, user_models, with_theme: false).to_h do
          [_1[:id], _1]
        end

        livestream_id = reaction_models.first.fetch(:livestream_id)
        livestream_model = tx.xquery('SELECT * FROM livestreams WHERE id = ?', livestream_id).first
        livestream = fill_livestream_response(tx, livestream_model)

        reaction_models.map do |reaction_model|
          user_id = reaction_model[:user_id]

          reaction_model.slice(:id, :emoji_name, :created_at).merge(
            user: users[user_id],
            livestream:,
          )
        end
      end

      def fill_reaction_response(tx, reaction_model)
        user_model = tx.xquery('SELECT * FROM users WHERE id = ?', reaction_model.fetch(:user_id)).first
        user = fill_user_response(tx, user_model)

        livestream_model = tx.xquery('SELECT * FROM livestreams WHERE id = ?', reaction_model.fetch(:livestream_id)).first
        livestream = fill_livestream_response(tx, livestream_model)

        reaction_model.slice(:id, :emoji_name, :created_at).merge(
          user:,
          livestream:,
        )
      end

      def fill_user_responses(tx, user_models, with_theme: true)
        return [] if user_models.size == 0

        user_ids = user_models.map{ _1[:id] }.join(",")

        theme_models = nil
        if with_theme
          theme_models = tx.xquery("SELECT * FROM themes WHERE user_id IN (#{user_ids})").to_h do
            [_1[:user_id], _1]
          end
        end

        user_models.map do |user_model|
          user_id = user_model.fetch(:id)

          {
            id: user_id,
            name: user_model.fetch(:name),
            display_name: user_model.fetch(:display_name),
            description: user_model.fetch(:description),
            theme: theme_models ? theme_models[user_id].slice(:id, :dark_mode) : {},
            icon_hash: user_model.fetch(:icon_hash),
          }
        end
      end

      def fill_user_response(tx, user_model, with_theme: true)
        theme_model = tx.xquery('SELECT * FROM themes WHERE user_id = ?', user_model.fetch(:id)).first if with_theme
        theme = with_theme ? {
          id: theme_model.fetch(:id),
          dark_mode: theme_model.fetch(:dark_mode),
        } : {}

        {
          id: user_model.fetch(:id),
          name: user_model.fetch(:name),
          display_name: user_model.fetch(:display_name),
          description: user_model.fetch(:description),
          theme: theme,
          icon_hash: user_model.fetch(:icon_hash),
        }
      end
    end

    # 初期化
    post '/api/initialize' do
      out, status = Open3.capture2e('../sql/init.sh')
      unless status.success?
        halt 500
      end

      json(
        language: 'ruby',
      )
    end

    # top
    get '/api/tag' do
      tag_models = db_conn.query('SELECT * FROM tags')

      json(
        tags: tag_models.map { |tag_model|
          {
            id: tag_model.fetch(:id),
            name: tag_model.fetch(:name),
          }
        },
      )
    end

    # 配信者のテーマ取得API
    get '/api/user/:username/theme' do
      verify_user_session!

      username = params[:username]

      theme_model = db_transaction do |tx|
        user_model = tx.xquery('SELECT id FROM users WHERE name = ?', username).first
        unless user_model
          raise HttpError.new(404)
        end
        tx.xquery('SELECT * FROM themes WHERE user_id = ?', user_model.fetch(:id)).first
      end

      json(
        id: theme_model.fetch(:id),
        dark_mode: theme_model.fetch(:dark_mode),
      )
    end

    # livestream

    ReserveLivestreamRequest = Data.define(
      :tags,
      :title,
      :description,
      :playlist_url,
      :thumbnail_url,
      :start_at,
      :end_at,
    )

    # reserve livestream
    post '/api/livestream/reservation' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      req = decode_request_body(ReserveLivestreamRequest)

      # 2023/11/25 10:00からの１年間の期間内であるかチェック
      term_start_at = Time.utc(2023, 11, 25, 1)
      term_end_at = Time.utc(2024, 11, 25, 1)
      reserve_start_at = Time.at(req.start_at, in: 'UTC')
      reserve_end_at = Time.at(req.end_at, in: 'UTC')
      if reserve_start_at >= term_end_at || reserve_end_at <= term_start_at
        raise HttpError.new(400, 'bad reservation time range')
      end

      livestream = db_transaction do |tx|
        # 予約枠をみて、予約が可能か調べる
        # NOTE: 並列な予約のoverbooking防止にFOR UPDATEが必要
        tx.xquery('SELECT * FROM reservation_slots WHERE start_at >= ? AND end_at <= ? FOR UPDATE', req.start_at, req.end_at).each do |slot|
          count = tx.xquery('SELECT slot FROM reservation_slots WHERE start_at = ? AND end_at = ?', slot.fetch(:start_at), slot.fetch(:end_at)).first.fetch(:slot)
          if count < 1
            raise HttpError.new(400, "予約期間 #{term_start_at.to_i} ~ #{term_end_at.to_i}に対して、予約区間 #{req.start_at} ~ #{req.end_at}が予約できません")
          end
        end

        tx.xquery('UPDATE reservation_slots SET slot = slot - 1 WHERE start_at >= ? AND end_at <= ?', req.start_at, req.end_at)
        tx.xquery('INSERT INTO livestreams (user_id, title, description, playlist_url, thumbnail_url, start_at, end_at) VALUES(?, ?, ?, ?, ?, ?, ?)', user_id, req.title, req.description, req.playlist_url, req.thumbnail_url, req.start_at, req.end_at)
        livestream_id = tx.last_id

	# タグ追加
        req.tags.each do |tag_id|
          tx.xquery('INSERT INTO livestream_tags (livestream_id, tag_id) VALUES (?, ?)', livestream_id, tag_id)
        end

        fill_livestream_response(tx, {
          id: livestream_id,
          user_id:,
          title: req.title,
          description: req.description,
          playlist_url: req.playlist_url,
          thumbnail_url: req.thumbnail_url,
          start_at: req.start_at,
          end_at: req.end_at,
        })
      end

      status 201
      json(livestream)
    end

    # list livestream
    get '/api/livestream/search' do
      key_tag_name = params[:tag] || ''

      tx = db_conn

      livestream_models =
        if key_tag_name != ''
          # タグによる取得
          tx.xquery(<<-SQL, key_tag_name).to_a
              SELECT livestreams.* FROM tags
              INNER JOIN livestream_tags ON livestream_tags.tag_id = tags.id
              INNER JOIN livestreams ON livestreams.id = livestream_tags.livestream_id
              WHERE tags.name = ?
              ORDER BY livestream_id DESC;
            SQL
        else
          # 検索条件なし
          query = 'SELECT * FROM livestreams ORDER BY id DESC'
          limit_str = params[:limit] || ''
          if limit_str != ''
            limit = cast_as_integer(limit_str)
            query = "#{query} LIMIT #{limit}"
          end

          tx.xquery(query).to_a
        end

      livestreams = fill_livestream_responses(tx, livestream_models)

      json(livestreams)
    end

    get '/api/livestream' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      tx = db_conn

      livestreams = tx.xquery('SELECT * FROM livestreams WHERE user_id = ?', user_id).map do |livestream_model|
        fill_livestream_response(tx, livestream_model)
      end

      json(livestreams)
    end

    get '/api/user/:username/livestream' do
      verify_user_session!
      username = params[:username]

      tx = db_conn

      user = tx.xquery('SELECT * FROM users WHERE name = ?', username).first
      unless user
        raise HttpError.new(404, 'user not found')
      end

      livestreams = tx.xquery('SELECT * FROM livestreams WHERE user_id = ?', user.fetch(:id)).map do |livestream_model|
        fill_livestream_response(tx, livestream_model)
      end

      json(livestreams)
    end

    # ユーザ視聴開始 (viewer)
    post '/api/livestream/:livestream_id/enter' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])

      created_at = Time.now.to_i
      db_conn.xquery('INSERT INTO livestream_viewers_history (user_id, livestream_id, created_at) VALUES(?, ?, ?)', user_id, livestream_id, created_at)

      ''
    end

    # ユーザ視聴終了 (viewer)
    delete '/api/livestream/:livestream_id/exit' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])

      db_conn.xquery('DELETE FROM livestream_viewers_history WHERE user_id = ? AND livestream_id = ?', user_id, livestream_id)

      ''
    end

    # get livestream
    get '/api/livestream/:livestream_id' do
      verify_user_session!

      livestream_id = cast_as_integer(params[:livestream_id])

      tx = db_conn

      livestream_model = tx.xquery('SELECT * FROM livestreams WHERE id = ?', livestream_id).first
      unless livestream_model
        raise HttpError.new(404)
      end

      livestream = fill_livestream_response(tx, livestream_model)

      json(livestream)
    end

    # (配信者向け)ライブコメントの報告一覧取得API
    get '/api/livestream/:livestream_id/report' do
      verify_user_session!

      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])

      tx = db_conn

      livestream_model = tx.xquery('SELECT * FROM livestreams WHERE id = ?', livestream_id).first
      if livestream_model.fetch(:user_id) != user_id
        raise HttpError.new(403, "can't get other streamer's livecomment reports")
      end

      reports = tx.xquery('SELECT * FROM livecomment_reports WHERE livestream_id = ?', livestream_id).map do |report_model|
        fill_livecomment_report_response(tx, report_model)
      end

      json(reports)
    end

    # get polling livecomment timeline
    get '/api/livestream/:livestream_id/livecomment' do
      verify_user_session!
      livestream_id = cast_as_integer(params[:livestream_id])

      tx = db_conn
      query = 'SELECT * FROM livecomments WHERE livestream_id = ? ORDER BY created_at DESC'
      limit_str = params[:limit] || ''
      if limit_str != ''
        limit = cast_as_integer(limit_str)
        query = "#{query} LIMIT #{limit}"
      end

      livecomment_models = tx.xquery(query, livestream_id)
      livecomments = fill_livecomment_responses(tx, livecomment_models)

      json(livecomments)
    end

    get '/api/livestream/:livestream_id/ngwords' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])

      ng_words = db_conn.xquery('SELECT * FROM ng_words WHERE user_id = ? AND livestream_id = ? ORDER BY created_at DESC', user_id, livestream_id).to_a

      json(ng_words)
    end

    PostLivecommentRequest = Data.define(
      :comment,
      :tip,
    )

    # ライブコメント投稿
    post '/api/livestream/:livestream_id/livecomment' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])

      req = decode_request_body(PostLivecommentRequest)

      livecomment = db_transaction do |tx|
        livestream_model = tx.xquery('SELECT * FROM livestreams WHERE id = ?', livestream_id).first
        unless livestream_model
          raise HttpError.new(404, 'livestream not found')
        end

        # スパム判定
        tx.xquery('SELECT id, user_id, livestream_id, word FROM ng_words WHERE user_id = ? AND livestream_id = ?', livestream_model.fetch(:user_id), livestream_model.fetch(:id)).each do |ng_word|
          if req.comment.include?(ng_word[:word])
            raise HttpError.new(400, 'このコメントがスパム判定されました')
          end
        end

        now = Time.now.to_i
        tx.xquery('INSERT INTO livecomments (user_id, livestream_id, comment, tip, created_at) VALUES (?, ?, ?, ?, ?)', user_id, livestream_id, req.comment, req.tip, now)
        livecomment_id = tx.last_id

        fill_livecomment_response(tx, {
          id: livecomment_id,
          user_id:,
          livestream_id:,
          comment: req.comment,
          tip: req.tip,
          created_at: now,
        })
      end

      status 201
      json(livecomment)
    end

    # ライブコメント報告
    post '/api/livestream/:livestream_id/livecomment/:livecomment_id/report' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless user_id
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])
      livecomment_id = cast_as_integer(params[:livecomment_id])

      report = db_transaction do |tx|
        livestream_model = tx.xquery('SELECT * FROM livestreams WHERE id = ?', livestream_id).first
        unless livestream_model
          raise HttpError.new(404, 'livestream not found')
        end

        livecomment_model = tx.xquery('SELECT * FROM livecomments WHERE id = ?', livecomment_id).first
        unless livecomment_model
          raise HttpError.new(404, 'livecomment not found')
        end

        now = Time.now.to_i
        tx.xquery('INSERT INTO livecomment_reports(user_id, livestream_id, livecomment_id, created_at) VALUES (?, ?, ?, ?)', user_id, livestream_id, livecomment_id, now)
        report_id = tx.last_id

        fill_livecomment_report_response(tx, {
          id: report_id,
          user_id:,
          livestream_id:,
          livecomment_id:,
          created_at: now,
        })
      end

      status 201
      json(report)
    end

    ModerateRequest = Data.define(:ng_word)

    # 配信者によるモデレーション (NGワード登録)
    post '/api/livestream/:livestream_id/moderate' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless user_id
        raise HttpError.new(401)
      end

      livestream_id = cast_as_integer(params[:livestream_id])

      req = decode_request_body(ModerateRequest)

      word_id = db_transaction do |tx|
        # 配信者自身の配信に対するmoderateなのかを検証
        owned_livestreams = tx.xquery('SELECT * FROM livestreams WHERE id = ? AND user_id = ?', livestream_id, user_id).to_a
        if owned_livestreams.empty?
          raise HttpError.new(400, "A streamer can't moderate livestreams that other streamers own")
        end

        tx.xquery('INSERT INTO ng_words(user_id, livestream_id, word, created_at) VALUES (?, ?, ?, ?)', user_id, livestream_id, req.ng_word, Time.now.to_i)
        word_id = tx.last_id

        # NGワードにヒットする過去の投稿も全削除する
        tx.xquery('SELECT * FROM ng_words WHERE livestream_id = ?', livestream_id).each do |ng_word|
          word = ng_word.fetch(:word)

          query = <<~SQL
            DELETE FROM livecomments WHERE livestream_id = ? AND livecomments.comment LIKE '%#{word}%'
          SQL
          tx.xquery(query, livestream_id)
        end

        word_id
      end

      status 201
      json(word_id:)
    end

    get '/api/livestream/:livestream_id/reaction' do
      verify_user_session!

      livestream_id = cast_as_integer(params[:livestream_id])

      tx = db_conn

      query = 'SELECT * FROM reactions WHERE livestream_id = ? ORDER BY created_at DESC'
      limit_str = params[:limit] || ''
      if limit_str != ''
        limit = cast_as_integer(limit_str)
        query = "#{query} LIMIT #{limit}"
      end

      reaction_models = tx.xquery(query, livestream_id)
      reactions = fill_reaction_responses(tx, reaction_models)

      json(reactions)
    end

    PostReactionRequest = Data.define(:emoji_name)

    post '/api/livestream/:livestream_id/reaction' do
      verify_user_session!
      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless user_id
        raise HttpError.new(401)
      end

      livestream_id = Integer(params[:livestream_id], 10)

      req = decode_request_body(PostReactionRequest)

      reaction = db_transaction do |tx|
        created_at = Time.now.to_i
        tx.xquery('INSERT INTO reactions (user_id, livestream_id, emoji_name, created_at) VALUES (?, ?, ?, ?)', user_id, livestream_id, req.emoji_name, created_at)
        reaction_id = tx.last_id

        fill_reaction_response(tx, {
          id: reaction_id,
          user_id:,
          livestream_id:,
          emoji_name: req.emoji_name,
          created_at:,
        })
      end

      status 201
      json(reaction)
    end

    BCRYPT_DEFAULT_COST = 4
    FALLBACK_IMAGE = '../img/NoImage.jpg'

    get '/api/user/:username/icon' do
      username = params[:username]

      user = db_conn.xquery('SELECT * FROM users WHERE name = ?', username).first
      unless user
        raise HttpError.new(404, 'not found user that has the given username')
      end

      icon_hash = user[:icon_hash]
      if icon_hash && "\"#{icon_hash}\"" == request.env["HTTP_IF_NONE_MATCH"]
        status 304
        return body nil
      end

      image = dc.get(user.fetch(:id))

      content_type 'image/jpeg'
      if image
        image
      else
        send_file FALLBACK_IMAGE
      end
    end

    PostIconRequest = Data.define(:image)

    post '/api/icon' do
      verify_user_session!

      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless user_id
        raise HttpError.new(401)
      end

      req = decode_request_body(PostIconRequest)
      image = Base64.decode64(req.image)
      icon_hash = Digest::SHA256.hexdigest(image)

      db_transaction do |tx|
        tx.xquery('UPDATE users SET icon_hash = ? WHERE id = ?', icon_hash, user_id)
        dc.set(user_id, image)
      end

      status 201
      json(
        id: user_id,
      )
    end

    get '/api/user/me' do
      verify_user_session!

      sess = session[DEFAULT_SESSION_ID_KEY]
      unless sess
        raise HttpError.new(401)
      end
      user_id = sess[DEFAULT_USER_ID_KEY]
      unless user_id
        raise HttpError.new(401)
      end

      user = db_transaction do |tx|
        user_model = tx.xquery('SELECT * FROM users WHERE id = ?', user_id).first
        unless user_model
          raise HttpError.new(404)
        end
        fill_user_response(tx, user_model)
      end

      json(user)
    end

    PostUserRequest = Data.define(
      :name,
      :display_name,
      :description,
      # password is non-hashed password.
      :password,
      :theme,
    )

    # ユーザ登録API
    post '/api/register' do
      req = decode_request_body(PostUserRequest)
      if req.name == 'pipe'
        raise HttpError.new(400, "the username 'pipe' is reserved")
      end

      hashed_password = BCrypt::Password.create(req.password, cost: BCRYPT_DEFAULT_COST)

      user = db_transaction do |tx|
        tx.xquery('INSERT INTO users (name, display_name, description, password) VALUES(?, ?, ?, ?)', req.name, req.display_name, req.description, hashed_password)
        user_id = tx.last_id

        tx.xquery('INSERT INTO themes (user_id, dark_mode) VALUES(?, ?)', user_id, req.theme.fetch(:dark_mode))

        out, status = Open3.capture2e('pdnsutil', 'add-record', 'u.isucon.local', req.name, 'A', '0', POWERDNS_SUBDOMAIN_ADDRESS)
        unless status.success?
          raise HttpError.new(500, "pdnsutil failed with out=#{out}")
        end

        fill_user_response(tx, {
          id: user_id,
          name: req.name,
          display_name: req.display_name,
          description: req.description,
          icon_hash: "d9f8294e9d895f81ce62e73dc7d5dff862a4fa40bd4e0fecf53f7526a8edcac0"
        })
      end

      status 201
      json(user)
    end

    LoginRequest = Data.define(
      :username,
      # password is non-hashed password.
      :password,
    )

    # ユーザログインAPI
    post '/api/login' do
      req = decode_request_body(LoginRequest)

      user_model = db_transaction do |tx|
        # usernameはUNIQUEなので、whereで一意に特定できる
        tx.xquery('SELECT * FROM users WHERE name = ?', req.username).first.tap do |user_model|
          unless user_model
            raise HttpError.new(401, 'invalid username or password')
          end
        end
      end

      unless BCrypt::Password.new(user_model.fetch(:password)).is_password?(req.password)
        raise HttpError.new(401, 'invalid username or password')
      end

      session_end_at = Time.now + 10*60*60
      session_id = SecureRandom.uuid
      session[DEFAULT_SESSION_ID_KEY] = {
        DEFAULT_SESSION_ID_KEY => session_id,
        DEFAULT_USER_ID_KEY => user_model.fetch(:id),
        DEFAULT_USERNAME_KEY => user_model.fetch(:name),
        DEFAULT_SESSION_EXPIRES_KEY => session_end_at.to_i,
      }

      ''
    end

    # ユーザ詳細API
    get '/api/user/:username' do
      verify_user_session!

      username = params[:username]

      user = db_transaction do |tx|
        user_model = tx.xquery('SELECT * FROM users WHERE name = ?', username).first
        unless user_model
          raise HttpError.new(404)
        end

        fill_user_response(tx, user_model)
      end

      json(user)
    end

    UserRankingEntry = Data.define(:username, :score)

    get '/api/user/:username/statistics' do
      verify_user_session!

      username = params[:username]

      # ユーザごとに、紐づく配信について、累計リアクション数、累計ライブコメント数、累計売上金額を算出
      # また、現在の合計視聴者数もだす

      stats = db_transaction do |tx|
        user = tx.xquery('SELECT * FROM users WHERE name = ?', username).first
        unless user
          raise HttpError.new(400)
        end

        # ランク算出
        users = tx.xquery('SELECT * FROM users').to_a
        reactions = tx.xquery('SELECT livestreams.user_id, COUNT(reactions.id) AS point_a FROM livestreams INNER JOIN reactions ON reactions.livestream_id = livestreams.id GROUP BY livestreams.user_id;')
                      .to_h { [_1[:user_id], _1[:point_a]] }
        tips = tx.xquery('SELECT livestreams.user_id, SUM(livecomments.tip) AS point_b FROM livestreams INNER JOIN livecomments ON livecomments.livestream_id = livestreams.id WHERE livecomments.tip > 0 GROUP BY livestreams.user_id;')
                 .to_h { [_1[:user_id], _1[:point_b]] }

        ranking = users.map do |user|
          a = reactions[user[:id]] || 0
          b = tips[user[:id]] || 0
          score = a + b
          UserRankingEntry.new(username: user.fetch(:name), score:)
        end

        ranking.sort_by! { |entry| [entry.score, entry.username] }
        ridx = ranking.rindex { |entry| entry.username == username }
        rank = ranking.size - ridx

        # リアクション数
        total_reactions = reactions[user[:id]]

        # ライブコメント数、チップ合計
        total_livecomments = 0
        total_tip = 0
        livestreams = tx.xquery('SELECT * FROM livestreams WHERE user_id = ?', user.fetch(:id))
        livestreams.each do |livestream|
          tx.xquery('SELECT * FROM livecomments WHERE livestream_id = ?', livestream.fetch(:id)).each do |livecomment|
            total_tip += livecomment.fetch(:tip)
            total_livecomments += 1
          end
        end

        # 合計視聴者数
        viewers_count = 0
        livestreams.each do |livestream|
          cnt = tx.xquery('SELECT COUNT(*) FROM livestream_viewers_history WHERE livestream_id = ?', livestream.fetch(:id), as: :array).first[0]
          viewers_count += cnt
        end

        # お気に入り絵文字
        favorite_emoji = tx.xquery(<<~SQL, username).first&.fetch(:emoji_name)
          SELECT r.emoji_name
          FROM users u
          INNER JOIN livestreams l ON l.user_id = u.id
          INNER JOIN reactions r ON r.livestream_id = l.id
          WHERE u.name = ?
          GROUP BY emoji_name
          ORDER BY COUNT(*) DESC, emoji_name DESC
          LIMIT 1
        SQL

        {
          rank:,
          viewers_count:,
          total_reactions:,
          total_livecomments:,
          total_tip:,
          favorite_emoji:,
        }
      end

      json(stats)
    end

    LivestreamRankingEntry = Data.define(:livestream_id, :score)

    # ライブ配信統計情報
    get '/api/livestream/:livestream_id/statistics' do
      verify_user_session!
      livestream_id = cast_as_integer(params[:livestream_id])

      stats = db_transaction do |tx|
        unless tx.xquery('SELECT * FROM livestreams WHERE id = ?', livestream_id).first
          raise HttpError.new(400)
        end

        # ランク算出
        livestreams = tx.xquery('SELECT * FROM livestreams')
        reactions = tx.xquery('SELECT livestreams.id, COUNT(reactions.id) AS point_a FROM livestreams INNER JOIN reactions ON reactions.livestream_id = livestreams.id GROUP BY livestreams.id;')
                      .to_h { [_1[:id], _1[:point_a]] }
        tips = tx.xquery('SELECT livestreams.id, SUM(livecomments.tip) AS point_b FROM livestreams INNER JOIN livecomments ON livecomments.livestream_id = livestreams.id WHERE livecomments.tip > 0 GROUP BY livestreams.id;')
                 .to_h { [_1[:id], _1[:point_b]] }

        ranking = livestreams.map do |livestream|
          a = reactions[livestream[:id]] || 0
          b = tips[livestream[:id]] || 0
          score = a + b
          LivestreamRankingEntry.new(livestream_id: livestream.fetch(:id), score:)
        end
        ranking.sort_by! { |entry| [entry.score, entry.livestream_id] }
        ridx = ranking.rindex { |entry| entry.livestream_id == livestream_id }
        rank = ranking.size - ridx

	# 視聴者数算出
        viewers_count = tx.xquery('SELECT COUNT(*) FROM livestreams l INNER JOIN livestream_viewers_history h ON h.livestream_id = l.id WHERE l.id = ?', livestream_id, as: :array).first[0]

	# 最大チップ額
        max_tip = tx.xquery('SELECT IFNULL(MAX(tip), 0) FROM livestreams l INNER JOIN livecomments l2 ON l2.livestream_id = l.id WHERE l.id = ?', livestream_id, as: :array).first[0]

	# リアクション数
        total_reactions = reactions[livestream_id] || 0

	# スパム報告数
        total_reports = tx.xquery('SELECT COUNT(*) FROM livestreams l INNER JOIN livecomment_reports r ON r.livestream_id = l.id WHERE l.id = ?', livestream_id, as: :array).first[0]

        {
          rank:,
          viewers_count:,
          max_tip:,
          total_reactions:,
          total_reports:,
        }
      end

      json(stats)
    end

    get '/api/payment' do
      total_tip = db_transaction do |tx|
        tx.xquery('SELECT IFNULL(SUM(tip), 0) FROM livecomments', as: :array).first[0]
      end

      json(total_tip:)
    end
  end
end
