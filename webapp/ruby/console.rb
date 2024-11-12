require 'bundler/setup'

Bundler.require
Dotenv.load("/home/isucon/env.sh")

require 'racksh/irb'

# オーバライドして色々試せるようにする
class Isupipe::App
  helpers do
    def verify_user_session!
      nil
    end
  end
end

# 試しうちの例
# response = $rack.get('/api/livestream/2/livecomment')
# JSON.parse(response.body)
