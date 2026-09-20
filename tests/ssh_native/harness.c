#include <libssh/libssh.h>
#include <libssh/sftp.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *read_fixture(const char *root, const char *name) {
    char path[2048], buffer[8192];
    if (snprintf(path,sizeof(path),"%s/%s",root,name) >= (int)sizeof(path)) return NULL;
    FILE *file=fopen(path,"rb"); if (!file) return NULL;
    size_t count=fread(buffer,1,sizeof(buffer)-1,file);
    int too_large=!feof(file); fclose(file); if (too_large) return NULL;
    while(count && (buffer[count-1]=='\n' || buffer[count-1]=='\r')) count--;
    buffer[count]=0; return strdup(buffer);
}
static int trusted(ssh_session session,const char *root,int bad) {
    ssh_key key=NULL; unsigned char *hash=NULL; size_t length=0;
    if(ssh_get_server_publickey(session,&key)!=SSH_OK) return 0;
    int rc=ssh_get_publickey_hash(key,SSH_PUBLICKEY_HASH_SHA256,&hash,&length);
    ssh_key_free(key); if(rc!=SSH_OK) return 0;
    char *fingerprint=ssh_get_fingerprint_hash(SSH_PUBLICKEY_HASH_SHA256,hash,length);
    char *expected=read_fixture(root,bad?"host-fingerprint-bad":"host-fingerprint");
    int ok=fingerprint && expected && !strncmp(fingerprint,"SHA256:",7) && !strcmp(fingerprint+7,expected);
    ssh_string_free_char(fingerprint); ssh_clean_pubkey_hash(&hash); free(expected);
    return ok;
}
static int password(ssh_session session,const char *root,int bad) {
    char *value=read_fixture(root,bad?"password-bad":"password"); if(!value)return 0;
    int rc=ssh_userauth_password(session,NULL,value); free(value); return rc==SSH_AUTH_SUCCESS;
}
static int keyboard(ssh_session session,const char *root,int bad,int *rounds) {
    char *answers=read_fixture(root,"kbd-answers"); if(!answers)return 0;
    char *second=strchr(answers,'\n'); if(!second){free(answers);return 0;} *second++=0;
    int rc=ssh_userauth_kbdint(session,NULL,NULL), index=0;
    while(rc==SSH_AUTH_INFO && *rounds<4) {
        (*rounds)++;
        int prompts=ssh_userauth_kbdint_getnprompts(session);
        if(prompts<0 || prompts>8)break;
        for(int i=0;i<prompts;i++) {
            const char *answer=index==0?answers:(index==1&&!bad?second:"wrong");
            if(ssh_userauth_kbdint_setanswer(session,(unsigned)i,answer)!=SSH_OK) {free(answers);return 0;}
            index++;
        }
        rc=ssh_userauth_kbdint(session,NULL,NULL);
    }
    free(answers); return rc==SSH_AUTH_SUCCESS;
}
static int key_auth(ssh_session session,const char *root,const char *name) {
    char path[2048]; ssh_key key=NULL;
    if(snprintf(path,sizeof(path),"%s/keys/%s",root,name)>=(int)sizeof(path))return 0;
    if(ssh_pki_import_privkey_file(path,NULL,NULL,NULL,&key)!=SSH_OK)return 0;
    int rc=ssh_userauth_publickey(session,NULL,key); ssh_key_free(key); return rc==SSH_AUTH_SUCCESS;
}
static int read_until(ssh_channel channel,const char *needle) {
    char buffer[8192]={0}; size_t used=0;
    for(int attempts=0;attempts<8 && used<sizeof(buffer)-1;attempts++) {
        int count=ssh_channel_read_timeout(channel,buffer+used,(uint32_t)(sizeof(buffer)-used-1),0,500);
        if(count<0)return 0;
        used+=(size_t)count; buffer[used]=0;
        if(strstr(buffer,needle))return 1;
        if(ssh_channel_is_eof(channel))break;
    }
    return 0;
}
static int channel_test(ssh_session session,int pty) {
    ssh_channel channel=ssh_channel_new(session); if(!channel)return 0;
    int ok=ssh_channel_open_session(channel)==SSH_OK;
    if(pty && ok) {
        ok=ssh_channel_request_pty_size(channel,"xterm",80,24)==SSH_OK &&
            ssh_channel_request_shell(channel)==SSH_OK && read_until(channel,"READY");
        if(ok)ok=ssh_channel_change_pty_size(channel,100,40)==SSH_OK && read_until(channel,"RESIZED:100x40");
        if(ok)ok=ssh_channel_write(channel,"ping\n",5)==5 && read_until(channel,"PONG");
        if(ok)(void)ssh_channel_write(channel,"exit\n",5);
    } else if(ok) {
        ok=ssh_channel_request_exec(channel,"printf cmux-fixed-output")==SSH_OK &&
            read_until(channel,"cmux-fixed-output");
    }
    ssh_channel_send_eof(channel); ssh_channel_close(channel); ssh_channel_free(channel); return ok;
}
static int sftp_test(ssh_session session) {
    sftp_session sftp=sftp_new(session); if(!sftp)return 0;
    if(sftp_init(sftp)!=SSH_OK) {sftp_free(sftp);return 0;}
    sftp_file file=sftp_open(sftp,"/fixture.txt",O_RDONLY,0);
    char bytes[64]={0}; ssize_t count=file?sftp_read(file,bytes,sizeof(bytes)-1):-1;
    int ok=count>0 && strstr(bytes,"fixture-sftp")!=NULL;
    if(file)sftp_close(file); sftp_free(sftp); return ok;
}
int main(int argc,char **argv) {
    if(argc!=5)return 2;
    const char *mode=argv[1], *root=argv[3]; int port=atoi(argv[2]);
    int expected=!strcmp(argv[4],"--expect-success"), config=0, rounds=0;
    long seconds=4;
    ssh_session session=ssh_new(); if(!session)return 2;
    if(ssh_options_set(session,SSH_OPTIONS_PROCESS_CONFIG,&config)!=SSH_OK ||
       ssh_options_set(session,SSH_OPTIONS_HOST,"127.0.0.1")!=SSH_OK ||
       ssh_options_set(session,SSH_OPTIONS_PORT,&port)!=SSH_OK ||
       ssh_options_set(session,SSH_OPTIONS_USER,"fixture")!=SSH_OK ||
       ssh_options_set(session,SSH_OPTIONS_TIMEOUT,&seconds)!=SSH_OK ||
       ssh_connect(session)!=SSH_OK) {
        puts("{\"ok\":false,\"error\":\"setup failed\"}"); ssh_free(session);return 1;
    }
    int pin=trusted(session,root,!strcmp(mode,"hostkey-bad")), auth=0, op=0;
    int host_case=!strncmp(mode,"hostkey-",8);
    if(host_case)op=pin;
    else if(pin) {
        if(!strncmp(mode,"password-",9))auth=password(session,root,!strcmp(mode,"password-bad"));
        else if(!strncmp(mode,"kbd-",4))auth=keyboard(session,root,!strcmp(mode,"kbd-bad"),&rounds);
        else if(!strcmp(mode,"key-ed25519"))auth=key_auth(session,root,"user_ed25519");
        else if(!strcmp(mode,"key-rsa"))auth=key_auth(session,root,"user_rsa");
        else {
            auth=password(session,root,0);
            if(auth) {
                if(!strcmp(mode,"exec"))op=channel_test(session,0);
                if(!strcmp(mode,"pty-resize"))op=channel_test(session,1);
                if(!strcmp(mode,"sftp"))op=sftp_test(session);
            }
        }
    }
    int auth_case=!strncmp(mode,"password-",9)||!strncmp(mode,"kbd-",4)||!strncmp(mode,"key-",4);
    int observed=host_case?pin:(auth_case?auth:(pin&&auth&&op));
    int ok=observed==expected && (strcmp(mode,"kbd-ok") || rounds==2);
    printf("{\"mode\":\"%s\",\"ok\":%s,\"pin\":%d,\"authenticated\":%d,\"operation\":%d,\"challengeRounds\":%d}\n",
           mode,ok?"true":"false",pin,auth,op,rounds);
    ssh_disconnect(session);ssh_free(session);return ok?0:1;
}
