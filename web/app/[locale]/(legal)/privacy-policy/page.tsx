import type { Metadata } from "next";
import type { ReactNode } from "react";

import type { Locale } from "../../../../i18n/routing";
import { buildAlternates } from "../../../../i18n/seo";
import {
  type PrivacyPolicySection,
  type PrivacyPolicySubsection,
  privacyPolicyForLocale,
} from "./content";

type PageProps = {
  readonly params: Promise<{ readonly locale: string }>;
};

export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
  const { locale } = await params;
  const content = privacyPolicyForLocale(locale);
  return {
    title: content.metadataTitle,
    description: content.metadataDescription,
    alternates: buildAlternates(locale, "/privacy-policy"),
  };
}

export default async function PrivacyPolicyPage({ params }: PageProps) {
  const { locale } = await params;
  const content = privacyPolicyForLocale(locale);
  const sections = [
    ...content.sections.slice(0, 2),
    irohDisclosureForLocale(locale),
    ...content.sections.slice(2),
  ];

  return (
    <>
      <h1>{content.title}</h1>
      <p>{lastUpdatedForLocale(locale)}</p>
      {sections.map((section, index) => (
        <PolicySection key={index} section={section} />
      ))}
    </>
  );
}

const lastUpdatedByLocale = {
  en: "Last updated: July 14, 2026",
  ja: "最終更新日: 2026 年 7 月 14 日",
  "zh-CN": "最后更新：2026 年 7 月 14 日",
  "zh-TW": "最後更新：2026 年 7 月 14 日",
  ko: "최종 업데이트: 2026년 7월 14일",
  de: "Zuletzt aktualisiert: 14. Juli 2026",
  es: "Última actualización: 14 de julio de 2026",
  fr: "Dernière mise à jour : 14 juillet 2026",
  it: "Ultimo aggiornamento: 14 luglio 2026",
  da: "Senest opdateret: 14. juli 2026",
  pl: "Ostatnia aktualizacja: 14 lipca 2026 r.",
  ru: "Последнее обновление: 14 июля 2026 г.",
  bs: "Posljednje ažuriranje: 14. juli 2026.",
  ar: "آخر تحديث: 14 يوليو 2026",
  no: "Sist oppdatert: 14. juli 2026",
  "pt-BR": "Última atualização: 14 de julho de 2026",
  th: "อัปเดตล่าสุด: 14 กรกฎาคม 2026",
  tr: "Son güncelleme: 14 Temmuz 2026",
  km: "បានធ្វើបច្ចុប្បន្នភាពចុងក្រោយ៖ 14 កក្កដា 2026",
  uk: "Останнє оновлення: 14 липня 2026 р.",
} satisfies Record<Locale, string>;

function lastUpdatedForLocale(locale: string): string {
  return lastUpdatedByLocale[locale as Locale] ?? lastUpdatedByLocale.en;
}

const irohDisclosures = {
  en: {
    heading: "Iroh networking",
    paragraphs: [
      "Iroh provides encrypted device-to-device networking for cmux mobile connectivity. Our account service processes your Iroh EndpointID, device and app-instance identifiers, signed reachability records, relay selection, custom-relay address metadata, connection timing, and credential-expiry metadata. Custom-relay secrets remain in secure storage on your device and are not synchronized to us.",
      "A relay can observe source and destination IP addresses, EndpointIDs, connection timing, and traffic volume, but cannot decrypt cmux session content. A direct peer-to-peer connection reveals each device’s network address to the other authenticated device. If you configure a relay operated by another provider, that provider’s privacy policy also applies.",
    ],
  },
  ja: {
    heading: "Iroh ネットワーキング",
    paragraphs: [
      "Iroh は、cmux のモバイル接続に暗号化されたデバイス間ネットワークを提供します。当社のアカウントサービスは、Iroh EndpointID、デバイスおよびアプリインスタンスの識別子、署名済み到達可能性レコード、リレーの選択、カスタムリレーのアドレスメタデータ、接続時刻、認証情報の有効期限メタデータを処理します。カスタムリレーのシークレットはデバイスの安全なストレージに残り、当社には同期されません。",
      "リレーは送信元と送信先の IP アドレス、EndpointID、接続時刻、通信量を確認できますが、cmux セッションの内容を復号できません。直接のピアツーピア接続では、認証済みの各デバイスに相手のネットワークアドレスが開示されます。別のプロバイダーが運営するリレーを設定した場合、そのプロバイダーのプライバシーポリシーも適用されます。",
    ],
  },
  "zh-CN": {
    heading: "Iroh 网络",
    paragraphs: [
      "Iroh 为 cmux 移动连接提供加密的设备间网络。我们的账户服务会处理您的 Iroh EndpointID、设备和应用实例标识符、已签名的可达性记录、中继选择、自定义中继地址元数据、连接时间以及凭据到期元数据。自定义中继密钥仅保存在您设备的安全存储中，不会同步给我们。",
      "中继可以看到源和目标 IP 地址、EndpointID、连接时间及流量，但无法解密 cmux 会话内容。直接的点对点连接会向另一台已认证设备公开每台设备的网络地址。如果您配置由其他提供商运营的中继，该提供商的隐私政策也适用。",
    ],
  },
  "zh-TW": {
    heading: "Iroh 網路",
    paragraphs: [
      "Iroh 為 cmux 行動連線提供加密的裝置對裝置網路。我們的帳戶服務會處理您的 Iroh EndpointID、裝置與應用程式執行個體識別碼、已簽署的可連線性記錄、中繼選擇、自訂中繼位址中繼資料、連線時間及憑證到期中繼資料。自訂中繼密鑰只會保存在您裝置的安全儲存空間中，不會同步給我們。",
      "中繼可以看到來源與目的地 IP 位址、EndpointID、連線時間及流量，但無法解密 cmux 工作階段內容。直接的點對點連線會向另一台已驗證裝置揭露每台裝置的網路位址。如果您設定由其他供應商營運的中繼，該供應商的隱私權政策也適用。",
    ],
  },
  ko: {
    heading: "Iroh 네트워킹",
    paragraphs: [
      "Iroh는 cmux 모바일 연결을 위해 암호화된 기기 간 네트워킹을 제공합니다. 당사 계정 서비스는 Iroh EndpointID, 기기 및 앱 인스턴스 식별자, 서명된 연결 가능성 기록, 릴레이 선택, 사용자 지정 릴레이 주소 메타데이터, 연결 시각 및 자격 증명 만료 메타데이터를 처리합니다. 사용자 지정 릴레이 비밀은 기기의 보안 저장소에만 보관되며 당사에 동기화되지 않습니다.",
      "릴레이는 출발지 및 목적지 IP 주소, EndpointID, 연결 시각 및 트래픽 양을 확인할 수 있지만 cmux 세션 내용을 복호화할 수 없습니다. 직접 피어 투 피어 연결은 인증된 상대 기기에 각 기기의 네트워크 주소를 공개합니다. 다른 제공업체가 운영하는 릴레이를 구성하면 해당 제공업체의 개인정보 보호정책도 적용됩니다.",
    ],
  },
  de: {
    heading: "Iroh-Netzwerk",
    paragraphs: [
      "Iroh stellt verschlüsselte Verbindungen zwischen Geräten für die mobile cmux-Verbindung bereit. Unser Kontodienst verarbeitet Ihre Iroh EndpointID, Geräte- und App-Instanzkennungen, signierte Erreichbarkeitsdatensätze, die Relaisauswahl, Adressmetadaten benutzerdefinierter Relais sowie Metadaten zu Verbindungszeitpunkt und Ablauf von Zugangsdaten. Geheimnisse benutzerdefinierter Relais verbleiben im sicheren Speicher Ihres Geräts und werden nicht mit uns synchronisiert.",
      "Ein Relais kann Quell- und Ziel-IP-Adressen, EndpointIDs, Verbindungszeiten und Datenvolumen sehen, aber den Inhalt der cmux-Sitzung nicht entschlüsseln. Bei einer direkten Peer-to-Peer-Verbindung wird die Netzwerkadresse jedes Geräts dem anderen authentifizierten Gerät offengelegt. Wenn Sie ein Relais eines anderen Anbieters konfigurieren, gilt auch dessen Datenschutzrichtlinie.",
    ],
  },
  es: {
    heading: "Red de Iroh",
    paragraphs: [
      "Iroh proporciona redes cifradas entre dispositivos para la conectividad móvil de cmux. Nuestro servicio de cuentas procesa su EndpointID de Iroh, identificadores del dispositivo y de la instancia de la aplicación, registros de accesibilidad firmados, selección de relés, metadatos de direcciones de relés personalizados y metadatos de tiempos de conexión y caducidad de credenciales. Los secretos de los relés personalizados permanecen en el almacenamiento seguro de su dispositivo y no se sincronizan con nosotros.",
      "Un relé puede observar las direcciones IP de origen y destino, los EndpointID, los tiempos de conexión y el volumen de tráfico, pero no puede descifrar el contenido de la sesión de cmux. Una conexión directa entre pares revela la dirección de red de cada dispositivo al otro dispositivo autenticado. Si configura un relé operado por otro proveedor, también se aplica la política de privacidad de ese proveedor.",
    ],
  },
  fr: {
    heading: "Réseau Iroh",
    paragraphs: [
      "Iroh fournit un réseau chiffré entre appareils pour la connectivité mobile de cmux. Notre service de compte traite votre EndpointID Iroh, les identifiants de l’appareil et de l’instance de l’application, les enregistrements d’accessibilité signés, le choix des relais, les métadonnées d’adresse des relais personnalisés ainsi que les métadonnées de date de connexion et d’expiration des identifiants. Les secrets des relais personnalisés restent dans le stockage sécurisé de votre appareil et ne sont pas synchronisés avec nous.",
      "Un relais peut observer les adresses IP source et destination, les EndpointID, les horaires de connexion et le volume du trafic, mais ne peut pas déchiffrer le contenu d’une session cmux. Une connexion pair à pair directe révèle l’adresse réseau de chaque appareil à l’autre appareil authentifié. Si vous configurez un relais exploité par un autre fournisseur, la politique de confidentialité de ce fournisseur s’applique également.",
    ],
  },
  it: {
    heading: "Rete Iroh",
    paragraphs: [
      "Iroh fornisce una rete cifrata tra dispositivi per la connettività mobile di cmux. Il nostro servizio account elabora l’EndpointID Iroh, gli identificatori del dispositivo e dell’istanza dell’app, i record di raggiungibilità firmati, la selezione dei relay, i metadati degli indirizzi dei relay personalizzati e i metadati relativi ai tempi di connessione e alla scadenza delle credenziali. I segreti dei relay personalizzati restano nell’archivio sicuro del dispositivo e non vengono sincronizzati con noi.",
      "Un relay può osservare gli indirizzi IP di origine e destinazione, gli EndpointID, i tempi di connessione e il volume del traffico, ma non può decifrare il contenuto della sessione cmux. Una connessione peer-to-peer diretta rivela l’indirizzo di rete di ciascun dispositivo all’altro dispositivo autenticato. Se configuri un relay gestito da un altro fornitore, si applica anche l’informativa sulla privacy di tale fornitore.",
    ],
  },
  da: {
    heading: "Iroh-netværk",
    paragraphs: [
      "Iroh leverer krypteret netværk mellem enheder til cmux-mobilforbindelser. Vores kontotjeneste behandler din Iroh EndpointID, enheds- og appinstans-id’er, signerede poster om tilgængelighed, valg af relæ, adressemetadata for brugerdefinerede relæer samt metadata om forbindelsestid og udløb af legitimationsoplysninger. Hemmeligheder til brugerdefinerede relæer forbliver i sikkert lager på din enhed og synkroniseres ikke med os.",
      "Et relæ kan se kilde- og destinations-IP-adresser, EndpointID’er, forbindelsestid og trafikmængde, men kan ikke dekryptere indholdet af en cmux-session. En direkte peer-to-peer-forbindelse viser hver enheds netværksadresse til den anden godkendte enhed. Hvis du konfigurerer et relæ, der drives af en anden udbyder, gælder dennes privatlivspolitik også.",
    ],
  },
  pl: {
    heading: "Sieć Iroh",
    paragraphs: [
      "Iroh zapewnia szyfrowaną komunikację między urządzeniami na potrzeby łączności mobilnej cmux. Nasza usługa konta przetwarza Twój Iroh EndpointID, identyfikatory urządzenia i instancji aplikacji, podpisane rekordy osiągalności, wybór przekaźnika, metadane adresów niestandardowych przekaźników oraz metadane czasu połączenia i wygaśnięcia danych uwierzytelniających. Sekrety niestandardowych przekaźników pozostają w bezpiecznej pamięci urządzenia i nie są z nami synchronizowane.",
      "Przekaźnik może obserwować źródłowe i docelowe adresy IP, EndpointID, czas połączenia i wielkość ruchu, ale nie może odszyfrować zawartości sesji cmux. Bezpośrednie połączenie peer-to-peer ujawnia adres sieciowy każdego urządzenia drugiemu uwierzytelnionemu urządzeniu. Jeśli skonfigurujesz przekaźnik obsługiwany przez innego dostawcę, zastosowanie ma również polityka prywatności tego dostawcy.",
    ],
  },
  ru: {
    heading: "Сеть Iroh",
    paragraphs: [
      "Iroh обеспечивает зашифрованное сетевое соединение между устройствами для мобильного подключения cmux. Наша служба учётных записей обрабатывает ваш Iroh EndpointID, идентификаторы устройства и экземпляра приложения, подписанные записи о доступности, выбор ретранслятора, метаданные адресов пользовательских ретрансляторов, а также метаданные времени подключения и срока действия учётных данных. Секреты пользовательских ретрансляторов остаются в защищённом хранилище вашего устройства и не синхронизируются с нами.",
      "Ретранслятор может видеть исходный и целевой IP-адреса, EndpointID, время подключения и объём трафика, но не может расшифровать содержимое сеанса cmux. Прямое одноранговое соединение раскрывает сетевой адрес каждого устройства другому прошедшему проверку устройству. Если вы настроите ретранслятор другого поставщика, также применяется политика конфиденциальности этого поставщика.",
    ],
  },
  bs: {
    heading: "Iroh umrežavanje",
    paragraphs: [
      "Iroh pruža šifrirano umrežavanje između uređaja za cmux mobilnu povezanost. Naša usluga računa obrađuje vaš Iroh EndpointID, identifikatore uređaja i instance aplikacije, potpisane zapise o dostupnosti, izbor releja, metapodatke adrese prilagođenog releja te metapodatke o vremenu veze i isteku vjerodajnica. Tajne prilagođenog releja ostaju u sigurnoj pohrani na vašem uređaju i ne sinhroniziraju se s nama.",
      "Relej može vidjeti izvornu i odredišnu IP adresu, EndpointID, vrijeme veze i količinu prometa, ali ne može dešifrirati sadržaj cmux sesije. Direktna peer-to-peer veza otkriva mrežnu adresu svakog uređaja drugom autentificiranom uređaju. Ako konfigurirate relej kojim upravlja drugi pružalac, primjenjuje se i politika privatnosti tog pružaoca.",
    ],
  },
  ar: {
    heading: "شبكة Iroh",
    paragraphs: [
      "يوفر Iroh شبكة مشفرة بين الأجهزة لاتصال cmux عبر الهاتف المحمول. تعالج خدمة الحساب لدينا Iroh EndpointID ومعرّفات الجهاز ومثيل التطبيق وسجلات إمكانية الوصول الموقعة واختيار المرحّل وبيانات عنوان المرحّل المخصص وبيانات وقت الاتصال وانتهاء صلاحية بيانات الاعتماد. تبقى أسرار المرحّل المخصص في التخزين الآمن على جهازك ولا تتم مزامنتها معنا.",
      "يمكن للمرحّل رؤية عناوين IP للمصدر والوجهة وEndpointID وتوقيت الاتصال وحجم حركة البيانات، لكنه لا يستطيع فك تشفير محتوى جلسة cmux. يكشف الاتصال المباشر من نظير إلى نظير عنوان شبكة كل جهاز للجهاز الآخر الذي تمت مصادقته. إذا أعددت مرحّلًا يديره مزود آخر، فتنطبق أيضًا سياسة الخصوصية الخاصة بذلك المزود.",
    ],
  },
  no: {
    heading: "Iroh-nettverk",
    paragraphs: [
      "Iroh tilbyr kryptert nettverk mellom enheter for cmux-mobiltilkobling. Kontotjenesten vår behandler Iroh EndpointID, identifikatorer for enhet og appforekomst, signerte tilgjengelighetsoppføringer, valg av relé, adressemetadata for egendefinerte reléer samt metadata om tilkoblingstid og utløp av legitimasjon. Hemmeligheter for egendefinerte reléer forblir i sikker lagring på enheten og synkroniseres ikke med oss.",
      "Et relé kan se kilde- og mål-IP-adresser, EndpointID-er, tilkoblingstid og trafikkmengde, men kan ikke dekryptere innholdet i en cmux-økt. En direkte node-til-node-tilkobling viser nettverksadressen til hver enhet for den andre autentiserte enheten. Hvis du konfigurerer et relé som drives av en annen leverandør, gjelder også denne leverandørens personvernerklæring.",
    ],
  },
  "pt-BR": {
    heading: "Rede Iroh",
    paragraphs: [
      "O Iroh fornece uma rede criptografada entre dispositivos para a conectividade móvel do cmux. Nosso serviço de conta processa seu EndpointID do Iroh, identificadores do dispositivo e da instância do aplicativo, registros assinados de acessibilidade, seleção de retransmissores, metadados de endereço de retransmissores personalizados e metadados de horário de conexão e expiração de credenciais. Os segredos de retransmissores personalizados permanecem no armazenamento seguro do seu dispositivo e não são sincronizados conosco.",
      "Um retransmissor pode observar os endereços IP de origem e destino, EndpointIDs, horários de conexão e volume de tráfego, mas não pode descriptografar o conteúdo da sessão do cmux. Uma conexão direta ponto a ponto revela o endereço de rede de cada dispositivo ao outro dispositivo autenticado. Se você configurar um retransmissor operado por outro provedor, a política de privacidade desse provedor também será aplicável.",
    ],
  },
  th: {
    heading: "เครือข่าย Iroh",
    paragraphs: [
      "Iroh ให้เครือข่ายแบบเข้ารหัสระหว่างอุปกรณ์สำหรับการเชื่อมต่อ cmux บนอุปกรณ์เคลื่อนที่ บริการบัญชีของเราประมวลผล Iroh EndpointID ตัวระบุอุปกรณ์และอินสแตนซ์แอป บันทึกความสามารถในการเข้าถึงที่ลงนามแล้ว การเลือกรีเลย์ ข้อมูลเมตาที่อยู่ของรีเลย์แบบกำหนดเอง และข้อมูลเมตาเวลาเชื่อมต่อและวันหมดอายุของข้อมูลรับรอง ความลับของรีเลย์แบบกำหนดเองจะอยู่ในพื้นที่จัดเก็บที่ปลอดภัยบนอุปกรณ์ของคุณและจะไม่ซิงค์กับเรา",
      "รีเลย์สามารถดูที่อยู่ IP ต้นทางและปลายทาง EndpointID เวลาเชื่อมต่อ และปริมาณการรับส่งข้อมูลได้ แต่ไม่สามารถถอดรหัสเนื้อหาเซสชัน cmux ได้ การเชื่อมต่อแบบเพียร์ทูเพียร์โดยตรงจะเปิดเผยที่อยู่เครือข่ายของแต่ละอุปกรณ์ให้อุปกรณ์ที่ผ่านการรับรองความถูกต้องอีกเครื่องทราบ หากคุณกำหนดค่ารีเลย์ที่ดำเนินการโดยผู้ให้บริการรายอื่น นโยบายความเป็นส่วนตัวของผู้ให้บริการนั้นจะมีผลด้วย",
    ],
  },
  tr: {
    heading: "Iroh ağı",
    paragraphs: [
      "Iroh, cmux mobil bağlantısı için cihazlar arasında şifreli ağ sağlar. Hesap hizmetimiz Iroh EndpointID’nizi, cihaz ve uygulama örneği tanımlayıcılarını, imzalı erişilebilirlik kayıtlarını, röle seçimini, özel röle adresi meta verilerini ve bağlantı zamanı ile kimlik bilgisi sona erme meta verilerini işler. Özel röle sırları cihazınızdaki güvenli depolamada kalır ve bizimle eşitlenmez.",
      "Bir röle kaynak ve hedef IP adreslerini, EndpointID’leri, bağlantı zamanını ve trafik hacmini görebilir ancak cmux oturum içeriğinin şifresini çözemez. Doğrudan eşler arası bağlantı, her cihazın ağ adresini kimliği doğrulanmış diğer cihaza açıklar. Başka bir sağlayıcı tarafından işletilen bir röle yapılandırırsanız o sağlayıcının gizlilik politikası da geçerli olur.",
    ],
  },
  km: {
    heading: "បណ្តាញ Iroh",
    paragraphs: [
      "Iroh ផ្តល់បណ្តាញដែលបានអ៊ិនគ្រីបរវាងឧបករណ៍សម្រាប់ការតភ្ជាប់ចល័ត cmux។ សេវាគណនីរបស់យើងដំណើរការ Iroh EndpointID របស់អ្នក អត្តសញ្ញាណឧបករណ៍ និងអ៊ីនស្តង់កម្មវិធី កំណត់ត្រាលទ្ធភាពភ្ជាប់ដែលបានចុះហត្ថលេខា ការជ្រើសរើស relay ទិន្នន័យមេតាអាសយដ្ឋាន relay ផ្ទាល់ខ្លួន និងទិន្នន័យមេតាពេលវេលាភ្ជាប់ និងការផុតកំណត់ព័ត៌មានសម្គាល់។ អាថ៌កំបាំង relay ផ្ទាល់ខ្លួននៅតែក្នុងកន្លែងផ្ទុកសុវត្ថិភាពលើឧបករណ៍របស់អ្នក ហើយមិនត្រូវបានធ្វើសមកាលកម្មមកយើងទេ។",
      "Relay អាចមើលឃើញអាសយដ្ឋាន IP ប្រភព និងគោលដៅ EndpointID ពេលវេលាភ្ជាប់ និងបរិមាណចរាចរណ៍ ប៉ុន្តែមិនអាចឌិគ្រីបមាតិកាសម័យ cmux បានទេ។ ការតភ្ជាប់ពីមួយទៅមួយដោយផ្ទាល់បង្ហាញអាសយដ្ឋានបណ្តាញរបស់ឧបករណ៍នីមួយៗដល់ឧបករណ៍ដែលបានផ្ទៀងផ្ទាត់មួយទៀត។ ប្រសិនបើអ្នកកំណត់ relay ដែលដំណើរការដោយអ្នកផ្តល់សេវាផ្សេង គោលការណ៍ឯកជនភាពរបស់អ្នកផ្តល់សេវានោះក៏អនុវត្តផងដែរ។",
    ],
  },
  uk: {
    heading: "Мережа Iroh",
    paragraphs: [
      "Iroh забезпечує зашифроване мережеве з’єднання між пристроями для мобільного підключення cmux. Наша служба облікових записів обробляє ваш Iroh EndpointID, ідентифікатори пристрою та екземпляра програми, підписані записи про доступність, вибір ретранслятора, метадані адрес користувацьких ретрансляторів, а також метадані часу підключення та завершення терміну дії облікових даних. Секрети користувацьких ретрансляторів залишаються в захищеному сховищі вашого пристрою й не синхронізуються з нами.",
      "Ретранслятор може бачити IP-адреси джерела та призначення, EndpointID, час підключення й обсяг трафіку, але не може розшифрувати вміст сеансу cmux. Пряме однорангове з’єднання розкриває мережеву адресу кожного пристрою іншому автентифікованому пристрою. Якщо ви налаштуєте ретранслятор іншого постачальника, також застосовується політика конфіденційності цього постачальника.",
    ],
  },
} satisfies Record<Locale, PrivacyPolicySection>;

function irohDisclosureForLocale(locale: string): PrivacyPolicySection {
  return irohDisclosures[locale as Locale] ?? irohDisclosures.en;
}

function PolicySection({ section }: { readonly section: PrivacyPolicySection }) {
  return (
    <>
      {section.heading ? <h2>{section.heading}</h2> : null}
      <PolicyBody content={section} />
      {section.subsections?.map((subsection, index) => (
        <PolicySubsection key={index} subsection={subsection} />
      ))}
    </>
  );
}

function PolicySubsection({
  subsection,
}: {
  readonly subsection: PrivacyPolicySubsection;
}) {
  return (
    <>
      <h3>{subsection.heading}</h3>
      <PolicyBody content={subsection} />
    </>
  );
}

function PolicyBody({
  content,
}: {
  readonly content: Pick<
    PrivacyPolicySection,
    "paragraphs" | "bullets" | "afterBullets"
  >;
}) {
  return (
    <>
      {content.paragraphs?.map((paragraph, index) => (
        <p key={`paragraph-${index}`}>{linkedText(paragraph)}</p>
      ))}
      {content.bullets?.length ? (
        <ul>
          {content.bullets.map((bullet, index) => (
            <li key={index}>{linkedText(bullet)}</li>
          ))}
        </ul>
      ) : null}
      {content.afterBullets?.map((paragraph, index) => (
        <p key={`after-${index}`}>{linkedText(paragraph)}</p>
      ))}
    </>
  );
}

const markdownLinkPattern = /\[([^\]]+)]\((https?:\/\/[^)]+|mailto:[^)]+)\)/g;

function linkedText(text: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  let cursor = 0;
  for (const match of text.matchAll(markdownLinkPattern)) {
    const index = match.index ?? 0;
    if (index > cursor) nodes.push(text.slice(cursor, index));
    nodes.push(
      <a key={`${index}-${match[2]}`} href={match[2]}>
        {match[1]}
      </a>,
    );
    cursor = index + match[0].length;
  }
  if (cursor < text.length) nodes.push(text.slice(cursor));
  return nodes;
}
