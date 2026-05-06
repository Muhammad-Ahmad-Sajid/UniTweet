-- -- ==========================================
-- -- Users Table
-- -- ==========================================
-- CREATE TABLE users (
--     reg_no VARCHAR(20) PRIMARY KEY,
--     full_name VARCHAR(100) NOT NULL,
--     email VARCHAR(255) UNIQUE NOT NULL,
--     batch_year INTEGER NOT NULL CHECK (batch_year >= 1900),
--     department VARCHAR(100) NOT NULL,
--     created_at TIMESTAMPTZ DEFAULT NOW()
-- );

-- -- ==========================================
-- -- Admins Table
-- -- ==========================================
-- CREATE TABLE admins (
--     admin_id SERIAL PRIMARY KEY,
--     username VARCHAR(50) UNIQUE NOT NULL,
--     email VARCHAR(255) UNIQUE NOT NULL,
--     password_hash TEXT NOT NULL,
--     created_at TIMESTAMPTZ DEFAULT NOW()
-- );

-- -- ==========================================
-- -- Tweets Table
-- -- ==========================================
-- CREATE TABLE tweets (
--     tweet_id SERIAL PRIMARY KEY,
--     author_reg_no VARCHAR(20) NOT NULL REFERENCES users(reg_no) ON DELETE CASCADE,
--     content TEXT NOT NULL CHECK (char_length(content) > 0 AND char_length(content) <= 280),
--     is_deleted BOOLEAN DEFAULT FALSE,
--     created_at TIMESTAMPTZ DEFAULT NOW()
-- );

-- -- ==========================================
-- -- Replies Table (Threaded Comments)
-- -- ==========================================
-- CREATE TABLE replies (
--     reply_id SERIAL PRIMARY KEY,
--     tweet_id INTEGER NOT NULL REFERENCES tweets(tweet_id) ON DELETE CASCADE,
--     author_reg_no VARCHAR(20) NOT NULL REFERENCES users(reg_no) ON DELETE CASCADE,
--     parent_reply_id INTEGER REFERENCES replies(reply_id) ON DELETE CASCADE, -- Allows for nested threaded replies
--     content TEXT NOT NULL CHECK (char_length(content) > 0 AND char_length(content) <= 280),
--     is_deleted BOOLEAN DEFAULT FALSE,
--     created_at TIMESTAMPTZ DEFAULT NOW()
-- );

-- -- ==========================================
-- -- Likes Table
-- -- ==========================================
-- CREATE TABLE likes (
--     like_id SERIAL PRIMARY KEY,
--     tweet_id INTEGER NOT NULL REFERENCES tweets(tweet_id) ON DELETE CASCADE,
--     user_reg_no VARCHAR(20) NOT NULL REFERENCES users(reg_no) ON DELETE CASCADE,
--     created_at TIMESTAMPTZ DEFAULT NOW(),
--     UNIQUE(tweet_id, user_reg_no) -- Prevents a user from liking the same tweet multiple times
-- );

-- -- ==========================================
-- -- Follows Table
-- -- ==========================================
-- CREATE TABLE follows (
--     follower_reg_no VARCHAR(20) NOT NULL REFERENCES users(reg_no) ON DELETE CASCADE,
--     following_reg_no VARCHAR(20) NOT NULL REFERENCES users(reg_no) ON DELETE CASCADE,
--     created_at TIMESTAMPTZ DEFAULT NOW(),
--     PRIMARY KEY (follower_reg_no, following_reg_no),
--     CHECK (follower_reg_no != following_reg_no) -- Prevents users from following themselves
-- );

-- -- ==========================================
-- -- Direct Messages Table
-- -- ==========================================
-- CREATE TABLE direct_messages (
--     message_id SERIAL PRIMARY KEY,
--     sender_reg_no VARCHAR(20) NOT NULL REFERENCES users(reg_no) ON DELETE CASCADE,
--     receiver_reg_no VARCHAR(20) NOT NULL REFERENCES users(reg_no) ON DELETE CASCADE,
--     content TEXT NOT NULL CHECK (char_length(content) > 0),
--     is_deleted BOOLEAN DEFAULT FALSE,
--     created_at TIMESTAMPTZ DEFAULT NOW(),
--     CHECK (sender_reg_no != receiver_reg_no) -- Prevents users from messaging themselves
-- );

-- -- ==========================================
-- -- Reports Table (Admin Moderation)
-- -- ==========================================
-- CREATE TABLE reports (
--     report_id SERIAL PRIMARY KEY,
--     reporter_reg_no VARCHAR(20) NOT NULL REFERENCES users(reg_no) ON DELETE CASCADE,
--     reported_tweet_id INTEGER REFERENCES tweets(tweet_id) ON DELETE CASCADE,
--     reported_user_reg_no VARCHAR(20) REFERENCES users(reg_no) ON DELETE CASCADE,
--     reason TEXT NOT NULL,
--     status VARCHAR(20) DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'REVIEWED', 'RESOLVED')),
--     created_at TIMESTAMPTZ DEFAULT NOW(),
--     CHECK (
--         (reported_tweet_id IS NOT NULL AND reported_user_reg_no IS NULL) OR 
--         (reported_tweet_id IS NULL AND reported_user_reg_no IS NOT NULL)
--     ) -- Ensures that a report is either for a tweet OR a user, not both or neither
-- );
-- Enable the pg_trgm extension required for the trigram-based GIN index
-- CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- -- The previous schema did not include a 'like_count' column. We need to add it 
-- -- to the tweets table first so we can index it for the trending feed.
-- ALTER TABLE tweets ADD COLUMN IF NOT EXISTS like_count INTEGER DEFAULT 0;

-- -- ==========================================
-- -- B-TREE INDEXES
-- -- ==========================================

-- -- Speeds up fetching a specific user's timeline/profile (finding all tweets by one author)
-- CREATE INDEX idx_tweets_user_id ON tweets(author_reg_no);

-- -- Speeds up loading the chronological timeline/feed (showing the latest tweets first)
-- CREATE INDEX idx_tweets_created_at ON tweets(created_at DESC);

-- -- Speeds up generating the trending feed by quickly sorting tweets by highest likes
-- CREATE INDEX idx_tweets_like_count ON tweets(like_count DESC);

-- -- Speeds up counting likes for a specific tweet or checking who liked a specific tweet
-- CREATE INDEX idx_likes_tweet_id ON likes(tweet_id);

-- -- Speeds up finding all users that a specific person is following (their "following" list)
-- CREATE INDEX idx_follows_follower ON follows(follower_reg_no);

-- -- Speeds up finding all followers of a specific user (their "followers" list)
-- CREATE INDEX idx_follows_followee ON follows(following_reg_no);

-- -- Speeds up looking up a user by their exact registration number.
-- -- (Note: PostgreSQL automatically creates an index for Primary Keys, but adding it explicitly as requested)
-- CREATE INDEX idx_users_reg_no ON users(reg_no);

-- -- Speeds up looking up a user during login or registration by exact email.
-- -- (Note: PostgreSQL automatically creates an index for UNIQUE constraints, but adding it explicitly as requested)
-- CREATE INDEX idx_users_email ON users(email);

-- -- Speeds up the admin dashboard when filtering reports by their status (e.g., fetching all 'PENDING' reports)
-- CREATE INDEX idx_reports_status ON reports(status);

-- -- Speeds up fetching the chat history between two specific users in Direct Messages
-- CREATE INDEX idx_dm_participants ON direct_messages(sender_reg_no, receiver_reg_no);

-- -- ==========================================
-- -- GIN INDEXES (Generalized Inverted Index)
-- -- ==========================================

-- -- Enables fast Full Text Search (FTS) on tweet content, allowing users to efficiently search for specific keywords
-- CREATE INDEX idx_tweets_fts ON tweets USING GIN (to_tsvector('english', content));

-- -- Enables fast partial-string / fuzzy search on user names (e.g., typing "ahm" will quickly find "Ahmad")
-- CREATE INDEX idx_users_name_trgm ON users USING GIN (full_name gin_trgm_ops);
-- ==========================================
-- 1. vw_tweet_details
-- Combines tweet data with the author's profile info and calculates the reply count dynamically.
-- Useful for rendering the main feed where you need both the tweet and the author's details.
-- ==========================================
-- CREATE OR REPLACE VIEW vw_tweet_details AS
-- SELECT 
--     t.tweet_id,
--     t.content,
--     t.like_count,
--     (SELECT COUNT(*) FROM replies r WHERE r.tweet_id = t.tweet_id AND r.is_deleted = FALSE) AS reply_count,
--     t.created_at,
--     u.reg_no AS user_id, -- Aliased as user_id as requested
--     u.reg_no,
--     u.full_name,
--     u.department
-- FROM tweets t
-- JOIN users u ON t.author_reg_no = u.reg_no
-- WHERE t.is_deleted = FALSE;

-- -- ==========================================
-- -- 2. vw_trending_tweets
-- -- Fetches the most popular tweets from the last 7 days based on likes.
-- -- This view builds directly on top of vw_tweet_details to reuse its JOIN logic.
-- -- ==========================================
-- CREATE OR REPLACE VIEW vw_trending_tweets AS
-- SELECT *
-- FROM vw_tweet_details
-- WHERE created_at >= NOW() - INTERVAL '7 days'
-- ORDER BY like_count DESC;

-- -- ==========================================
-- -- 3. vw_user_stats
-- -- Generates a complete profile overview for a user, calculating how many tweets they've made,
-- -- how many people follow them, and how many people they are following.
-- -- ==========================================
-- CREATE OR REPLACE VIEW vw_user_stats AS
-- SELECT 
--     u.reg_no,
--     u.full_name,
--     u.email,
--     u.department,
--     u.batch_year,
--     (SELECT COUNT(*) FROM tweets t WHERE t.author_reg_no = u.reg_no AND t.is_deleted = FALSE) AS tweet_count,
--     (SELECT COUNT(*) FROM follows f WHERE f.following_reg_no = u.reg_no) AS follower_count,
--     (SELECT COUNT(*) FROM follows f WHERE f.follower_reg_no = u.reg_no) AS following_count
-- FROM users u;

-- -- ==========================================
-- -- 4. vw_reply_details
-- -- Combines reply data with the replying user's profile info.
-- -- Useful for rendering the comment section under a specific tweet.
-- -- ==========================================
-- CREATE OR REPLACE VIEW vw_reply_details AS
-- SELECT 
--     r.reply_id,
--     r.tweet_id,
--     r.parent_reply_id,
--     r.content,
--     r.created_at,
--     u.reg_no AS author_reg_no,
--     u.full_name AS author_name
-- FROM replies r
-- JOIN users u ON r.author_reg_no = u.reg_no
-- WHERE r.is_deleted = FALSE;

-- -- ==========================================
-- -- 5. vw_pending_reports
-- -- Specifically tailored for the Admin Dashboard to review reports that need attention.
-- -- Uses LEFT JOINs so it works whether a User OR a Tweet was reported.
-- -- ==========================================
-- CREATE OR REPLACE VIEW vw_pending_reports AS
-- SELECT 
--     rep.report_id,
--     rep.reason,
--     rep.created_at AS report_date,
--     rep.reporter_reg_no,
--     u.full_name AS reporter_name,
--     rep.reported_tweet_id,
--     LEFT(t.content, 50) AS tweet_preview, -- Takes the first 50 chars of the tweet as a preview
--     rep.reported_user_reg_no,
--     ru.full_name AS reported_user_name
-- FROM reports rep
-- JOIN users u ON rep.reporter_reg_no = u.reg_no
-- LEFT JOIN tweets t ON rep.reported_tweet_id = t.tweet_id
-- LEFT JOIN users ru ON rep.reported_user_reg_no = ru.reg_no
-- WHERE rep.status = 'PENDING';

-- -- ==========================================
-- -- 6. vw_inbox_summary
-- -- Generates the "Inbox" view for a user, showing one row per conversation partner 
-- -- along with the text and timestamp of their most recent message exchanged.
-- -- Uses DISTINCT ON to grab only the latest message per thread.
-- -- ==========================================
-- CREATE OR REPLACE VIEW vw_inbox_summary AS
-- WITH conversation_messages AS (
--     -- Get messages where the user is the sender
--     SELECT 
--         sender_reg_no AS user_reg_no, 
--         receiver_reg_no AS partner_reg_no, 
--         content, 
--         created_at
--     FROM direct_messages
--     WHERE is_deleted = FALSE
--     UNION ALL
--     -- Get messages where the user is the receiver
--     SELECT 
--         receiver_reg_no AS user_reg_no, 
--         sender_reg_no AS partner_reg_no, 
--         content, 
--         created_at
--     FROM direct_messages
--     WHERE is_deleted = FALSE
-- )
-- SELECT DISTINCT ON (user_reg_no, partner_reg_no)
--     user_reg_no,
--     partner_reg_no,
--     content AS latest_message,
--     created_at AS message_time
-- FROM conversation_messages
-- ORDER BY user_reg_no, partner_reg_no, created_at DESC;
-- First, add the necessary columns to the tweets table if they don't exist yet
-- ALTER TABLE tweets ADD COLUMN IF NOT EXISTS reply_count INTEGER DEFAULT 0;
-- ALTER TABLE tweets ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

-- -- ==========================================
-- -- 1. trg_increment_like_count
-- -- Automatically increases the like_count on a tweet when someone likes it
-- -- ==========================================
-- CREATE OR REPLACE FUNCTION fn_increment_like_count() RETURNS TRIGGER AS $$
-- BEGIN
--     UPDATE tweets SET like_count = like_count + 1 WHERE tweet_id = NEW.tweet_id;
--     RETURN NEW;
-- END;
-- $$ LANGUAGE plpgsql;

-- CREATE TRIGGER trg_increment_like_count
-- AFTER INSERT ON likes
-- FOR EACH ROW
-- EXECUTE FUNCTION fn_increment_like_count();

-- -- ==========================================
-- -- 2. trg_decrement_like_count
-- -- Automatically decreases the like_count on a tweet when someone unlikes it.
-- -- Uses GREATEST to ensure it never drops below 0.
-- -- ==========================================
-- CREATE OR REPLACE FUNCTION fn_decrement_like_count() RETURNS TRIGGER AS $$
-- BEGIN
--     UPDATE tweets SET like_count = GREATEST(like_count - 1, 0) WHERE tweet_id = OLD.tweet_id;
--     RETURN OLD;
-- END;
-- $$ LANGUAGE plpgsql;

-- CREATE TRIGGER trg_decrement_like_count
-- AFTER DELETE ON likes
-- FOR EACH ROW
-- EXECUTE FUNCTION fn_decrement_like_count();

-- -- ==========================================
-- -- 3. trg_increment_reply_count
-- -- Automatically increases the reply_count on a tweet when a new reply is posted
-- -- ==========================================
-- CREATE OR REPLACE FUNCTION fn_increment_reply_count() RETURNS TRIGGER AS $$
-- BEGIN
--     UPDATE tweets SET reply_count = reply_count + 1 WHERE tweet_id = NEW.tweet_id;
--     RETURN NEW;
-- END;
-- $$ LANGUAGE plpgsql;

-- CREATE TRIGGER trg_increment_reply_count
-- AFTER INSERT ON replies
-- FOR EACH ROW
-- EXECUTE FUNCTION fn_increment_reply_count();

-- -- ==========================================
-- -- 4. trg_decrement_reply_count
-- -- Automatically decreases the reply_count when a reply is "soft deleted".
-- -- ==========================================
-- CREATE OR REPLACE FUNCTION fn_decrement_reply_count() RETURNS TRIGGER AS $$
-- BEGIN
--     UPDATE tweets SET reply_count = GREATEST(reply_count - 1, 0) WHERE tweet_id = NEW.tweet_id;
--     RETURN NEW;
-- END;
-- $$ LANGUAGE plpgsql;

-- CREATE TRIGGER trg_decrement_reply_count
-- AFTER UPDATE ON replies
-- FOR EACH ROW
-- WHEN (OLD.is_deleted = FALSE AND NEW.is_deleted = TRUE)
-- EXECUTE FUNCTION fn_decrement_reply_count();

-- -- ==========================================
-- -- 5. trg_prevent_self_like
-- -- Throws a custom error if a user attempts to like their own tweet
-- -- ==========================================
-- CREATE OR REPLACE FUNCTION fn_prevent_self_like() RETURNS TRIGGER AS $$
-- DECLARE
--     tweet_author VARCHAR(20);
-- BEGIN
--     -- Fetch the author of the tweet being liked
--     SELECT author_reg_no INTO tweet_author FROM tweets WHERE tweet_id = NEW.tweet_id;
    
--     IF NEW.user_reg_no = tweet_author THEN
--         RAISE EXCEPTION 'Users cannot like their own tweets.';
--     END IF;
--     RETURN NEW;
-- END;
-- $$ LANGUAGE plpgsql;

-- CREATE TRIGGER trg_prevent_self_like
-- BEFORE INSERT ON likes
-- FOR EACH ROW
-- EXECUTE FUNCTION fn_prevent_self_like();

-- -- ==========================================
-- -- 6. trg_prevent_self_follow
-- -- Throws a custom error if a user attempts to follow themselves
-- -- (Acts as a companion to our existing CHECK constraint for better error messages)
-- -- ==========================================
-- CREATE OR REPLACE FUNCTION fn_prevent_self_follow() RETURNS TRIGGER AS $$
-- BEGIN
--     IF NEW.follower_reg_no = NEW.following_reg_no THEN
--         RAISE EXCEPTION 'Users cannot follow themselves.';
--     END IF;
--     RETURN NEW;
-- END;
-- $$ LANGUAGE plpgsql;

-- CREATE TRIGGER trg_prevent_self_follow
-- BEFORE INSERT ON follows
-- FOR EACH ROW
-- EXECUTE FUNCTION fn_prevent_self_follow();

-- -- ==========================================
-- -- 7. trg_prevent_self_dm
-- -- Throws a custom error if a user attempts to send a DM to themselves
-- -- (Acts as a companion to our existing CHECK constraint for better error messages)
-- -- ==========================================
-- CREATE OR REPLACE FUNCTION fn_prevent_self_dm() RETURNS TRIGGER AS $$
-- BEGIN
--     IF NEW.sender_reg_no = NEW.receiver_reg_no THEN
--         RAISE EXCEPTION 'Users cannot send direct messages to themselves.';
--     END IF;
--     RETURN NEW;
-- END;
-- $$ LANGUAGE plpgsql;

-- CREATE TRIGGER trg_prevent_self_dm
-- BEFORE INSERT ON direct_messages
-- FOR EACH ROW
-- EXECUTE FUNCTION fn_prevent_self_dm();

-- -- ==========================================
-- -- 8. trg_tweet_updated_at
-- -- Automatically updates the updated_at timestamp whenever a tweet's content is modified
-- -- ==========================================
-- CREATE OR REPLACE FUNCTION fn_tweet_updated_at() RETURNS TRIGGER AS $$
-- BEGIN
--     NEW.updated_at = NOW();
--     RETURN NEW;
-- END;
-- $$ LANGUAGE plpgsql;

-- CREATE TRIGGER trg_tweet_updated_at
-- BEFORE UPDATE ON tweets
-- FOR EACH ROW
-- EXECUTE FUNCTION fn_tweet_updated_at();

-- -- ==========================================
-- -- 9. trg_cascade_delete_replies
-- -- When a main tweet is soft deleted, automatically soft delete all of its replies
-- -- ==========================================
-- CREATE OR REPLACE FUNCTION fn_cascade_delete_replies() RETURNS TRIGGER AS $$
-- BEGIN
--     UPDATE replies SET is_deleted = TRUE WHERE tweet_id = NEW.tweet_id;
--     RETURN NEW;
-- END;
-- $$ LANGUAGE plpgsql;

-- CREATE TRIGGER trg_cascade_delete_replies
-- AFTER UPDATE ON tweets
-- FOR EACH ROW
-- WHEN (OLD.is_deleted = FALSE AND NEW.is_deleted = TRUE)
-- EXECUTE FUNCTION fn_cascade_delete_replies();
-- Update the constraint on the reports table to allow the 'DISMISSED' status
-- ALTER TABLE reports DROP CONSTRAINT reports_status_check;
-- ALTER TABLE reports ADD CONSTRAINT reports_status_check 
--     CHECK (status IN ('PENDING', 'REVIEWED', 'RESOLVED', 'DISMISSED'));

-- -- ==========================================
-- -- 1. generate_user_report
-- -- Calculates total tweets, likes, and replies for a single user using a cursor
-- -- ==========================================
-- CREATE OR REPLACE FUNCTION generate_user_report(p_user_id VARCHAR) 
-- RETURNS TABLE(tweet_count INT, total_likes INT, total_replies INT) AS $$
-- DECLARE
--     -- 1. DECLARE the cursor
--     cur_tweets CURSOR FOR 
--         SELECT tweet_id, like_count, reply_count 
--         FROM tweets 
--         WHERE author_reg_no = p_user_id AND is_deleted = FALSE;
        
--     -- Variables to hold fetched row data
--     v_tweet_id INT;
--     v_like_count INT;
--     v_reply_count INT;
    
--     -- Accumulator variables
--     v_total_tweets INT := 0;
--     v_total_likes_acc INT := 0;
--     v_total_replies_acc INT := 0;
-- BEGIN
--     -- 2. OPEN the cursor
--     OPEN cur_tweets;
    
--     LOOP
--         -- 3. FETCH the next row
--         FETCH cur_tweets INTO v_tweet_id, v_like_count, v_reply_count;
        
--         -- EXIT loop when no more rows are found
--         EXIT WHEN NOT FOUND;
        
--         -- Accumulate the counts
--         v_total_tweets := v_total_tweets + 1;
--         v_total_likes_acc := v_total_likes_acc + v_like_count;
--         v_total_replies_acc := v_total_replies_acc + v_reply_count;
--     END LOOP;
    
--     -- 4. CLOSE the cursor
--     CLOSE cur_tweets;
    
--     -- Return the accumulated results as a table row
--     RETURN QUERY SELECT v_total_tweets, v_total_likes_acc, v_total_replies_acc;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- ==========================================
-- -- 2. admin_bulk_dismiss
-- -- Dismisses old PENDING reports and returns the number of reports dismissed
-- -- ==========================================
-- CREATE OR REPLACE FUNCTION admin_bulk_dismiss(p_days_old INT, p_admin_id INT) 
-- RETURNS INT AS $$
-- DECLARE
--     -- 1. DECLARE the cursor
--     cur_reports CURSOR FOR 
--         SELECT report_id 
--         FROM reports 
--         WHERE status = 'PENDING' 
--         AND created_at < NOW() - (p_days_old || ' days')::INTERVAL;
        
--     v_report_id INT;
--     v_dismissed_count INT := 0;
-- BEGIN
--     -- Note: p_admin_id is passed in, but since our reports table doesn't currently 
--     -- store WHICH admin resolved it, we don't save it. If you add an 'admin_id' 
--     -- column to reports later, you would include it in the UPDATE statement below.

--     -- 2. OPEN the cursor
--     OPEN cur_reports;
    
--     LOOP
--         -- 3. FETCH the next row
--         FETCH cur_reports INTO v_report_id;
        
--         -- EXIT loop when no more rows are found
--         EXIT WHEN NOT FOUND;
        
--         -- Update the specific report
--         UPDATE reports 
--         SET status = 'DISMISSED' 
--         WHERE report_id = v_report_id;
        
--         -- Increment our counter
--         v_dismissed_count := v_dismissed_count + 1;
--     END LOOP;
    
--     -- 4. CLOSE the cursor
--     CLOSE cur_reports;
    
--     -- Return the total number of reports dismissed
--     RETURN v_dismissed_count;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- ==========================================
-- -- 3. build_home_digest
-- -- Assembles a text digest of the latest 10 tweets from users the target user follows
-- -- ==========================================
-- CREATE OR REPLACE FUNCTION build_home_digest(p_user_id VARCHAR) 
-- RETURNS TEXT AS $$
-- DECLARE
--     -- 1. DECLARE the cursor
--     -- Joins vw_tweet_details with the follows table
--     cur_digest CURSOR FOR 
--         SELECT content, full_name 
--         FROM vw_tweet_details 
--         WHERE user_id IN (
--             SELECT following_reg_no 
--             FROM follows 
--             WHERE follower_reg_no = p_user_id
--         ) 
--         ORDER BY created_at DESC 
--         LIMIT 10;
        
--     v_content TEXT;
--     v_full_name VARCHAR;
--     v_digest_text TEXT := '';
-- BEGIN
--     -- 2. OPEN the cursor
--     OPEN cur_digest;
    
--     LOOP
--         -- 3. FETCH the next row
--         FETCH cur_digest INTO v_content, v_full_name;
        
--         -- EXIT loop when no more rows are found
--         EXIT WHEN NOT FOUND;
        
--         -- Concatenate into a text summary string
--         -- (chr(10) adds a newline for readability in text-only UIs)
--         v_digest_text := v_digest_text || v_full_name || ': "' || v_content || '"' || chr(10);
--     END LOOP;
    
--     -- 4. CLOSE the cursor
--     CLOSE cur_digest;
    
--     -- If the digest is completely empty, provide a default fallback message
--     IF v_digest_text = '' THEN
--         v_digest_text := 'Your timeline is empty. Follow some users to see their tweets here!';
--     END IF;
    
--     -- Return the assembled digest text
--     RETURN v_digest_text;
-- END;
-- $$ LANGUAGE plpgsql;
-- Ensure the users table has a password_hash column for the auth functions
-- ALTER TABLE users ADD COLUMN IF NOT EXISTS password_hash TEXT;

-- -- ==========================================
-- -- AUTH & USERS
-- -- ==========================================

-- -- 1. register_user
-- -- Inserts a new user into the database
-- CREATE OR REPLACE FUNCTION register_user(
--     p_reg_no VARCHAR, p_full_name VARCHAR, p_email VARCHAR, 
--     p_password_hash TEXT, p_batch_year INT, p_department VARCHAR
-- ) RETURNS void AS $$
-- BEGIN
--     INSERT INTO users (reg_no, full_name, email, password_hash, batch_year, department)
--     VALUES (p_reg_no, p_full_name, p_email, p_password_hash, p_batch_year, p_department);
-- END;
-- $$ LANGUAGE plpgsql;

-- -- 2. get_user_for_login
-- -- Fetches user credentials allowing login via either email or registration number
-- CREATE OR REPLACE FUNCTION get_user_for_login(p_identifier VARCHAR) 
-- RETURNS TABLE(user_id VARCHAR, reg_no VARCHAR, full_name VARCHAR, email VARCHAR, password_hash TEXT, department VARCHAR) AS $$
-- BEGIN
--     RETURN QUERY 
--     SELECT u.reg_no AS user_id, u.reg_no, u.full_name, u.email, u.password_hash, u.department
--     FROM users u
--     WHERE u.email = p_identifier OR u.reg_no = p_identifier;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- 3. get_user_profile
-- -- Gets profile stats and whether the currently logged-in user (caller) follows them
-- CREATE OR REPLACE FUNCTION get_user_profile(p_target_id VARCHAR, p_caller_id VARCHAR)
-- RETURNS TABLE(
--     user_id VARCHAR, reg_no VARCHAR, full_name VARCHAR, department VARCHAR, batch_year INT,
--     follower_count BIGINT, following_count BIGINT, tweet_count BIGINT, is_following_by_caller BOOLEAN
-- ) AS $$
-- BEGIN
--     RETURN QUERY
--     SELECT 
--         u.reg_no AS user_id, u.reg_no, u.full_name, u.department, u.batch_year,
--         (SELECT COUNT(*) FROM follows WHERE following_reg_no = u.reg_no) AS follower_count,
--         (SELECT COUNT(*) FROM follows WHERE follower_reg_no = u.reg_no) AS following_count,
--         (SELECT COUNT(*) FROM tweets WHERE author_reg_no = u.reg_no AND is_deleted = FALSE) AS tweet_count,
--         EXISTS(SELECT 1 FROM follows WHERE follower_reg_no = p_caller_id AND following_reg_no = u.reg_no) AS is_following_by_caller
--     FROM users u
--     WHERE u.reg_no = p_target_id;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- ==========================================
-- -- TWEETS
-- -- ==========================================

-- -- 4. create_tweet
-- -- Inserts a new tweet and returns its generated ID
-- CREATE OR REPLACE FUNCTION create_tweet(p_user_id VARCHAR, p_content VARCHAR) 
-- RETURNS INT AS $$
-- DECLARE
--     v_tweet_id INT;
-- BEGIN
--     INSERT INTO tweets (author_reg_no, content)
--     VALUES (p_user_id, p_content)
--     RETURNING tweet_id INTO v_tweet_id;
--     RETURN v_tweet_id;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- 5. delete_tweet
-- -- Soft deletes a tweet, validating that the requester is the actual owner
-- CREATE OR REPLACE FUNCTION delete_tweet(p_tweet_id INT, p_user_id VARCHAR) 
-- RETURNS void AS $$
-- DECLARE
--     v_owner VARCHAR;
-- BEGIN
--     SELECT author_reg_no INTO v_owner FROM tweets WHERE tweet_id = p_tweet_id;
    
--     IF NOT FOUND THEN
--         RAISE EXCEPTION 'Tweet not found';
--     END IF;
    
--     IF v_owner != p_user_id THEN
--         RAISE EXCEPTION 'Only the owner can delete this tweet';
--     END IF;
    
--     UPDATE tweets SET is_deleted = TRUE WHERE tweet_id = p_tweet_id;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- 6. get_tweet_by_id
-- -- Fetches a single tweet's full details using the view
-- CREATE OR REPLACE FUNCTION get_tweet_by_id(p_tweet_id INT) 
-- RETURNS SETOF vw_tweet_details AS $$
-- BEGIN
--     RETURN QUERY SELECT * FROM vw_tweet_details WHERE tweet_id = p_tweet_id;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- ==========================================
-- -- FEEDS
-- -- ==========================================

-- -- 7. get_home_feed
-- -- Fetches timeline: tweets from people the user follows AND their own tweets
-- CREATE OR REPLACE FUNCTION get_home_feed(p_user_id VARCHAR, p_offset INT, p_fetch INT)
-- RETURNS SETOF vw_tweet_details AS $$
-- BEGIN
--     RETURN QUERY
--     SELECT * FROM vw_tweet_details
--     WHERE user_id IN (SELECT following_reg_no FROM follows WHERE follower_reg_no = p_user_id)
--        OR user_id = p_user_id
--     ORDER BY created_at DESC
--     OFFSET p_offset LIMIT p_fetch;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- 8. get_trending_feed
-- -- Fetches the top liked tweets recently
-- CREATE OR REPLACE FUNCTION get_trending_feed(p_offset INT, p_fetch INT)
-- RETURNS SETOF vw_trending_tweets AS $$
-- BEGIN
--     RETURN QUERY SELECT * FROM vw_trending_tweets OFFSET p_offset LIMIT p_fetch;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- 9. get_user_tweets
-- -- Fetches the timeline for a specific user's profile
-- CREATE OR REPLACE FUNCTION get_user_tweets(p_user_id VARCHAR, p_offset INT, p_fetch INT)
-- RETURNS SETOF vw_tweet_details AS $$
-- BEGIN
--     RETURN QUERY SELECT * FROM vw_tweet_details WHERE user_id = p_user_id
--     ORDER BY created_at DESC OFFSET p_offset LIMIT p_fetch;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- ==========================================
-- -- LIKES
-- -- ==========================================

-- -- 10. toggle_like
-- -- If liked -> unlikes. If not liked -> likes. Returns true if it is now liked.
-- -- Note: like_count update is handled automatically by the trigger we created earlier.
-- CREATE OR REPLACE FUNCTION toggle_like(p_tweet_id INT, p_user_id VARCHAR) 
-- RETURNS BOOLEAN AS $$
-- DECLARE
--     v_liked BOOLEAN;
-- BEGIN
--     IF EXISTS (SELECT 1 FROM likes WHERE tweet_id = p_tweet_id AND user_reg_no = p_user_id) THEN
--         DELETE FROM likes WHERE tweet_id = p_tweet_id AND user_reg_no = p_user_id;
--         v_liked := FALSE;
--     ELSE
--         INSERT INTO likes (tweet_id, user_reg_no) VALUES (p_tweet_id, p_user_id);
--         v_liked := TRUE;
--     END IF;
--     RETURN v_liked;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- ==========================================
-- -- REPLIES
-- -- ==========================================

-- -- 11. add_reply
-- -- Inserts a reply. Note: reply_count is handled automatically by the trigger.
-- CREATE OR REPLACE FUNCTION add_reply(p_tweet_id INT, p_user_id VARCHAR, p_parent_reply_id INT, p_content VARCHAR)
-- RETURNS INT AS $$
-- DECLARE
--     v_reply_id INT;
-- BEGIN
--     INSERT INTO replies (tweet_id, author_reg_no, parent_reply_id, content)
--     VALUES (p_tweet_id, p_user_id, p_parent_reply_id, p_content)
--     RETURNING reply_id INTO v_reply_id;
--     RETURN v_reply_id;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- 12. get_replies
-- -- Uses a recursive CTE to build a threaded comment tree for a tweet
-- CREATE OR REPLACE FUNCTION get_replies(p_tweet_id INT)
-- RETURNS TABLE (
--     reply_id INT, tweet_id INT, parent_reply_id INT, content TEXT, 
--     created_at TIMESTAMPTZ, author_reg_no VARCHAR, author_name VARCHAR,
--     depth INT, path INT[]
-- ) AS $$
-- BEGIN
--     RETURN QUERY
--     WITH RECURSIVE reply_tree AS (
--         -- Base case: Top level comments
--         SELECT 
--             r.reply_id, r.tweet_id, r.parent_reply_id, r.content, r.created_at, 
--             r.author_reg_no, r.author_name,
--             1 AS depth, 
--             ARRAY[r.reply_id] AS path
--         FROM vw_reply_details r
--         WHERE r.tweet_id = p_tweet_id AND r.parent_reply_id IS NULL
        
--         UNION ALL
        
--         -- Recursive case: Replies to comments
--         SELECT 
--             r.reply_id, r.tweet_id, r.parent_reply_id, r.content, r.created_at, 
--             r.author_reg_no, r.author_name,
--             rt.depth + 1 AS depth, 
--             rt.path || r.reply_id AS path
--         FROM vw_reply_details r
--         INNER JOIN reply_tree rt ON r.parent_reply_id = rt.reply_id
--     )
--     SELECT * FROM reply_tree ORDER BY path;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- ==========================================
-- -- FOLLOWS
-- -- ==========================================

-- -- 13. toggle_follow
-- -- Toggles following status. Returns TRUE if now following.
-- CREATE OR REPLACE FUNCTION toggle_follow(p_source VARCHAR, p_target VARCHAR) 
-- RETURNS BOOLEAN AS $$
-- DECLARE
--     v_following BOOLEAN;
-- BEGIN
--     IF EXISTS (SELECT 1 FROM follows WHERE follower_reg_no = p_source AND following_reg_no = p_target) THEN
--         DELETE FROM follows WHERE follower_reg_no = p_source AND following_reg_no = p_target;
--         v_following := FALSE;
--     ELSE
--         INSERT INTO follows (follower_reg_no, following_reg_no) VALUES (p_source, p_target);
--         v_following := TRUE;
--     END IF;
--     RETURN v_following;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- 14. get_followers
-- CREATE OR REPLACE FUNCTION get_followers(p_user_id VARCHAR)
-- RETURNS TABLE(user_id VARCHAR, reg_no VARCHAR, full_name VARCHAR) AS $$
-- BEGIN
--     RETURN QUERY
--     SELECT u.reg_no AS user_id, u.reg_no, u.full_name
--     FROM follows f
--     JOIN users u ON f.follower_reg_no = u.reg_no
--     WHERE f.following_reg_no = p_user_id;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- 15. get_following
-- CREATE OR REPLACE FUNCTION get_following(p_user_id VARCHAR)
-- RETURNS TABLE(user_id VARCHAR, reg_no VARCHAR, full_name VARCHAR) AS $$
-- BEGIN
--     RETURN QUERY
--     SELECT u.reg_no AS user_id, u.reg_no, u.full_name
--     FROM follows f
--     JOIN users u ON f.following_reg_no = u.reg_no
--     WHERE f.follower_reg_no = p_user_id;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- ==========================================
-- -- DIRECT MESSAGES
-- -- ==========================================

-- -- 16. send_message
-- CREATE OR REPLACE FUNCTION send_message(p_sender VARCHAR, p_receiver VARCHAR, p_content TEXT)
-- RETURNS INT AS $$
-- DECLARE
--     v_msg_id INT;
-- BEGIN
--     INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content)
--     VALUES (p_sender, p_receiver, p_content)
--     RETURNING message_id INTO v_msg_id;
--     RETURN v_msg_id;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- 17. get_conversation
-- -- Gets paginated messages between two specific users
-- CREATE OR REPLACE FUNCTION get_conversation(p_a VARCHAR, p_b VARCHAR, p_offset INT, p_fetch INT)
-- RETURNS TABLE(message_id INT, sender_reg_no VARCHAR, receiver_reg_no VARCHAR, content TEXT, created_at TIMESTAMPTZ) AS $$
-- BEGIN
--     RETURN QUERY
--     SELECT dm.message_id, dm.sender_reg_no, dm.receiver_reg_no, dm.content, dm.created_at
--     FROM direct_messages dm
--     WHERE (dm.sender_reg_no = p_a AND dm.receiver_reg_no = p_b AND dm.is_deleted = FALSE)
--        OR (dm.sender_reg_no = p_b AND dm.receiver_reg_no = p_a AND dm.is_deleted = FALSE)
--     ORDER BY dm.created_at DESC
--     OFFSET p_offset LIMIT p_fetch;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- 18. get_inbox
-- CREATE OR REPLACE FUNCTION get_inbox(p_user_id VARCHAR)
-- RETURNS SETOF vw_inbox_summary AS $$
-- BEGIN
--     RETURN QUERY SELECT * FROM vw_inbox_summary WHERE user_reg_no = p_user_id;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- ==========================================
-- -- SEARCH
-- -- ==========================================

-- -- 19. search_users
-- -- Searches users by name, reg_no, or department (case insensitive)
-- CREATE OR REPLACE FUNCTION search_users(p_query VARCHAR)
-- RETURNS TABLE(user_id VARCHAR, reg_no VARCHAR, full_name VARCHAR, department VARCHAR) AS $$
-- BEGIN
--     RETURN QUERY
--     SELECT u.reg_no AS user_id, u.reg_no, u.full_name, u.department
--     FROM users u
--     WHERE u.full_name ILIKE '%' || p_query || '%' 
--        OR u.reg_no ILIKE '%' || p_query || '%'
--        OR u.department ILIKE '%' || p_query || '%';
-- END;
-- $$ LANGUAGE plpgsql;

-- -- 20. search_tweets
-- -- Full text search on tweets utilizing the GIN index we created
-- CREATE OR REPLACE FUNCTION search_tweets(p_query VARCHAR)
-- RETURNS SETOF vw_tweet_details AS $$
-- BEGIN
--     RETURN QUERY
--     SELECT * FROM vw_tweet_details
--     WHERE to_tsvector('english', content) @@ plainto_tsquery('english', p_query);
-- END;
-- $$ LANGUAGE plpgsql;

-- -- ==========================================
-- -- ADMIN
-- -- ==========================================

-- -- 21. get_pending_reports
-- CREATE OR REPLACE FUNCTION get_pending_reports(p_offset INT, p_fetch INT)
-- RETURNS SETOF vw_pending_reports AS $$
-- BEGIN
--     RETURN QUERY SELECT * FROM vw_pending_reports ORDER BY report_date ASC OFFSET p_offset LIMIT p_fetch;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- 22. resolve_report_delete
-- -- Resolves a report by soft deleting the tweet it references
-- CREATE OR REPLACE FUNCTION resolve_report_delete(p_report_id INT, p_admin_id INT)
-- RETURNS void AS $$
-- DECLARE
--     v_tweet_id INT;
-- BEGIN
--     SELECT reported_tweet_id INTO v_tweet_id FROM reports WHERE report_id = p_report_id;
    
--     IF v_tweet_id IS NOT NULL THEN
--         UPDATE tweets SET is_deleted = TRUE WHERE tweet_id = v_tweet_id;
--     END IF;
    
--     UPDATE reports SET status = 'RESOLVED' WHERE report_id = p_report_id;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- 23. resolve_report_dismiss
-- -- Dismisses a report without deleting anything
-- CREATE OR REPLACE FUNCTION resolve_report_dismiss(p_report_id INT, p_admin_id INT)
-- RETURNS void AS $$
-- BEGIN
--     UPDATE reports SET status = 'DISMISSED' WHERE report_id = p_report_id;
-- END;
-- $$ LANGUAGE plpgsql;

-- -- 24. create_report
-- -- Dynamically handles reporting either a tweet or a user based on the target_type
-- CREATE OR REPLACE FUNCTION create_report(p_reporter_id VARCHAR, p_target_type VARCHAR, p_target_id VARCHAR, p_reason TEXT)
-- RETURNS void AS $$
-- BEGIN
--     IF p_target_type = 'TWEET' THEN
--         -- Cast the generic VARCHAR ID back to an INT for the tweet_id column
--         INSERT INTO reports (reporter_reg_no, reported_tweet_id, reason)
--         VALUES (p_reporter_id, p_target_id::INT, p_reason);
--     ELSIF p_target_type = 'USER' THEN
--         INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason)
--         VALUES (p_reporter_id, p_target_id, p_reason);
--     ELSE
--         RAISE EXCEPTION 'Invalid target type. Use TWEET or USER.';
--     END IF;
-- END;
-- $$ LANGUAGE plpgsql;
-- ==========================================
-- 1. USERS (30 realistic Pakistani students)
-- ==========================================
-- INSERT INTO users (reg_no, full_name, email, password_hash, batch_year, department) VALUES
-- ('24L-0941', 'Ahmad Sajid', 'ahmad.sajid@uni.edu.pk', 'hashed_password', 2024, 'CS'),
-- ('24L-0102', 'Ali Khan', 'ali.khan@uni.edu.pk', 'hashed_password', 2024, 'SE'),
-- ('24L-0103', 'Fatima Ahmed', 'fatima.ahmed@uni.edu.pk', 'hashed_password', 2024, 'AI'),
-- ('24L-0104', 'Bilal Chaudhry', 'bilal.c@uni.edu.pk', 'hashed_password', 2024, 'DS'),
-- ('24L-0105', 'Ayesha Syed', 'ayesha.syed@uni.edu.pk', 'hashed_password', 2024, 'CY'),
-- ('24L-0106', 'Hamza Malik', 'hamza.malik@uni.edu.pk', 'hashed_password', 2024, 'CS'),
-- ('24L-0107', 'Zainab Qureshi', 'zainab.q@uni.edu.pk', 'hashed_password', 2024, 'SE'),
-- ('24L-0108', 'Umar Farooq', 'umar.farooq@uni.edu.pk', 'hashed_password', 2024, 'AI'),
-- ('24L-0109', 'Sana Tariq', 'sana.tariq@uni.edu.pk', 'hashed_password', 2024, 'DS'),
-- ('24L-0110', 'Usman Raza', 'usman.raza@uni.edu.pk', 'hashed_password', 2024, 'CY'),
-- ('24L-0111', 'Iqra Hassan', 'iqra.hassan@uni.edu.pk', 'hashed_password', 2024, 'CS'),
-- ('24L-0112', 'Hassan Ali', 'hassan.ali@uni.edu.pk', 'hashed_password', 2024, 'SE'),
-- ('24L-0113', 'Nida Kamran', 'nida.k@uni.edu.pk', 'hashed_password', 2024, 'AI'),
-- ('24L-0114', 'Abdullah Shah', 'abdullah.shah@uni.edu.pk', 'hashed_password', 2024, 'DS'),
-- ('24L-0115', 'Maryam Baig', 'maryam.baig@uni.edu.pk', 'hashed_password', 2024, 'CY'),
-- ('23L-0201', 'Saad Imran', 'saad.imran@uni.edu.pk', 'hashed_password', 2023, 'CS'),
-- ('23L-0202', 'Hira Sheikh', 'hira.sheikh@uni.edu.pk', 'hashed_password', 2023, 'SE'),
-- ('23L-0203', 'Taha Salman', 'taha.s@uni.edu.pk', 'hashed_password', 2023, 'AI'),
-- ('23L-0204', 'Sadia Muneeb', 'sadia.m@uni.edu.pk', 'hashed_password', 2023, 'DS'),
-- ('23L-0205', 'Muneeb Qasim', 'muneeb.q@uni.edu.pk', 'hashed_password', 2023, 'CY'),
-- ('23L-0206', 'Rabia Siddiqui', 'rabia.s@uni.edu.pk', 'hashed_password', 2023, 'CS'),
-- ('23L-0207', 'Farhan Jamil', 'farhan.j@uni.edu.pk', 'hashed_password', 2023, 'SE'),
-- ('23L-0208', 'Khadija Rizvi', 'khadija.r@uni.edu.pk', 'hashed_password', 2023, 'AI'),
-- ('23L-0209', 'Salman Zafar', 'salman.z@uni.edu.pk', 'hashed_password', 2023, 'DS'),
-- ('23L-0210', 'Hussain Abbas', 'hussain.a@uni.edu.pk', 'hashed_password', 2023, 'CY'),
-- ('23L-0211', 'Mahnoor Asif', 'mahnoor.a@uni.edu.pk', 'hashed_password', 2023, 'CS'),
-- ('23L-0212', 'Shahzaib Akbar', 'shahzaib.a@uni.edu.pk', 'hashed_password', 2023, 'SE'),
-- ('23L-0213', 'Bisma Nadeem', 'bisma.n@uni.edu.pk', 'hashed_password', 2023, 'AI'),
-- ('23L-0214', 'Kamran Saeed', 'kamran.s@uni.edu.pk', 'hashed_password', 2023, 'DS'),
-- ('23L-0215', 'Zara Khalid', 'zara.khalid@uni.edu.pk', 'hashed_password', 2023, 'CY');

-- -- ==========================================
-- -- 2. ADMINS (2 records)
-- -- ==========================================
-- INSERT INTO admins (username, email, password_hash) VALUES
-- ('admin_root', 'admin@uni.edu.pk', 'hashed_password'),
-- ('moderator_01', 'mod01@uni.edu.pk', 'hashed_password');

-- -- ==========================================
-- -- 3. TWEETS (15 realistic records)
-- -- ==========================================
-- INSERT INTO tweets (author_reg_no, content) VALUES
-- ('24L-0941', 'Just finished setting up my Tkinter frontend. DB project is finally coming together!'),
-- ('24L-0102', 'Is the cafe in the CS block open today? Need coffee ASAP for this assignment.'),
-- ('24L-0103', 'Deep Learning is breaking my brain. Someone teach me backpropagation please 😭'),
-- ('24L-0104', 'Data Science midterms are out. Pray for me y''all.'),
-- ('24L-0105', 'Why does the university WiFi disconnect every 10 minutes? So frustrating!'),
-- ('24L-0106', 'Anyone playing FIFA in the boys lounge after 2 PM?'),
-- ('23L-0201', 'Seniors, any tips on getting a good FYP advisor?'),
-- ('23L-0202', 'Software Engineering diagrams are going to be the end of me. UML is a nightmare.'),
-- ('23L-0203', 'Machine learning class is actually super interesting this semester.'),
-- ('23L-0204', 'Who parked their white Civic directly behind my car in the parking lot?! 😡'),
-- ('24L-0111', 'Looking for group members for the Web Dev project. React/Node JS stack. HMU!'),
-- ('23L-0212', 'Missed the 8:30 AM class because of traffic on Canal Road again.'),
-- ('24L-0107', 'Can someone send the slides for Lecture 4 of Operating Systems?'),
-- ('23L-0215', 'Cybersecurity CTF competition this weekend! Who''s participating?'),
-- ('24L-0114', 'Just found out Python uses indentations instead of brackets... game changer.');

-- -- ==========================================
-- -- 4. FOLLOWS (20 relationships)
-- -- ==========================================
-- INSERT INTO follows (follower_reg_no, following_reg_no) VALUES
-- ('24L-0941', '24L-0102'), ('24L-0941', '24L-0103'), ('24L-0941', '23L-0201'),
-- ('24L-0102', '24L-0941'), ('24L-0102', '24L-0106'), ('24L-0103', '24L-0941'),
-- ('24L-0104', '23L-0204'), ('24L-0105', '24L-0111'), ('24L-0106', '24L-0102'),
-- ('23L-0201', '24L-0941'), ('23L-0201', '23L-0202'), ('23L-0202', '23L-0201'),
-- ('23L-0203', '24L-0103'), ('23L-0204', '24L-0104'), ('24L-0111', '24L-0105'),
-- ('23L-0212', '24L-0112'), ('24L-0114', '24L-0115'), ('23L-0215', '24L-0105'),
-- ('24L-0107', '23L-0202'), ('24L-0112', '23L-0212');

-- -- ==========================================
-- -- 5. LIKES (10 random likes on tweets)
-- -- ==========================================
-- -- Assuming tweet IDs are generated from 1 to 15 based on the inserts above
-- INSERT INTO likes (tweet_id, user_reg_no) VALUES
-- (1, '24L-0102'), (1, '24L-0103'), (2, '24L-0106'), 
-- (3, '23L-0203'), (5, '24L-0111'), (5, '23L-0212'), 
-- (7, '24L-0941'), (11, '24L-0105'), (12, '24L-0112'), 
-- (15, '23L-0201');

-- -- ==========================================
-- -- 6. DIRECT MESSAGES (5 realistic conversations)
-- -- ==========================================
-- INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES
-- ('24L-0102', '24L-0941', 'Hey Ahmad, how is the DB project going?'),
-- ('24L-0941', '24L-0102', 'Almost done with the GUI. Will send you the code tonight!'),
-- ('24L-0103', '23L-0203', 'Can you help me with the backpropagation assignment?'),
-- ('23L-0203', '24L-0103', 'Sure, let''s meet in the library at 3 PM.'),
-- ('24L-0104', '23L-0204', 'Did you find out who blocked your car?');

-- -- ==========================================
-- -- 7. REPORTS (3 pending reports)
-- -- ==========================================
-- INSERT INTO reports (reporter_reg_no, reported_tweet_id, reported_user_reg_no, reason, status) VALUES
-- ('24L-0102', 10, NULL, 'Using aggressive language regarding the parking issue.', 'PENDING'),
-- ('24L-0111', NULL, '23L-0212', 'Spamming the timeline with irrelevant posts.', 'PENDING'),
-- ('23L-0201', 5, NULL, 'Spreading false rumors about the university WiFi.', 'PENDING');

