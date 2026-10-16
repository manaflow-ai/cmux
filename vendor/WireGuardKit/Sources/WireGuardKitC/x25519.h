#ifndef X25519_H
#define X25519_H

void curve25519_derive_public_key(unsigned char public_key[32], const unsigned char private_key[32]);
void curve25519_generate_private_key(unsigned char private_key[32]);

#endif
