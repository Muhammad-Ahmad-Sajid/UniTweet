
      UniTweet - Database Project

1. SYSTEM REQUIREMENTS

- Python 3.8 or higher
- PostgreSQL 13 or higher

2. INSTALLING DEPENDENCIES

Before running the application, you need to install the required Python libraries. 
Open your terminal or command prompt in this folder and run:

    pip install psycopg2 firebase-admin bcrypt


3. POSTGRESQL DATABASE SETUP 

 1. Open pgAdmin4 and create a new database (e.g., named "unitweet").

4. RUNNING THE APPLICATION
-----------------------------------------
Once the database is set up and dependencies are installed, you can launch the app by running:

    python app.py

TEST ACCOUNTS:
You can log into the app using any of the generated accounts. 
Here are two specific testing accounts:
  - Registration No: 2024338
    Password: 338
    
  - Registration No: 2024307
    Password: 307

  - FOR ADMIN: Registration No/email: admin
               password: admin

5. EXTRA UTILITIES
-----------------------------------------
- `backup.py`: You can run this file from the terminal (`python backup.py`) to launch a command-line tool that syncs data bidirectionally between PostgreSQL and Firebase.

