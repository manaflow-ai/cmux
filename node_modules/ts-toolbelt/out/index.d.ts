declare module "Iteration/Iteration" {
    /**
    An entry of **`IterationMap`**
    * `[0]`: Prev (<-)
    * `[1]`: Next (->)
    * `[2]`: Current **`string`**
    * `[3]`: Current **`number`**
    * `[4]`: Current Negative **`string`**
    * `[5]`: Cumulated Previous **`keys`** (for `Min` & `Max`)
    * `[6]`: Sign (- / 0 / +)
    */
    export type Iteration = [
        string,
        string,
        string,
        number,
        string,
        string,
        '-' | '0' | '+'
    ];
}
declare module "Iteration/Map" {
    import { Iteration } from "Iteration/Iteration";
    /**
     * Defines a basic map that will be passed to [[CreateMap]]
     * @hidden
     */
    type RawMap = {
        [K in string]: Iteration;
    };
    /**
     * Serves the purpose of completing a [[RawMap]]'s boundaries
     * @hidden
     */
    type BoundMap = {
        [K in string]: ['__', '__', string, number, string, string, '-' | '0' | '+'];
    };
    /**
     * Defines how to define the keys that make a [[RawMap]]
     * @hidden
     */
    type Keys<M extends RawMap> = {
        '-': keyof M;
        '0': keyof M;
        '+': keyof M;
    };
    /**
    Describes a map of number relationships
    */
    export type Map = [
        Keys<RawMap>,
        RawMap
    ];
    /**
    Creates a [[Map]] of number relationships
    */
    export type CreateMap<K extends Keys<RawMap>, RM extends RawMap> = [
        K,
        RM & BoundMap
    ];
}
declare module "Iteration/Maps/Number" {
    import { CreateMap } from "Iteration/Map";
    /**
     * @hidden
     */
    type RawMap = {
        '-100': ['__', '-99', '-100', -100, '100', '-100', '-'];
        '-99': ['-100', '-98', '-99', -99, '99', RawMap['-100'][5] | '-99', '-'];
        '-98': ['-99', '-97', '-98', -98, '98', RawMap['-99'][5] | '-98', '-'];
        '-97': ['-98', '-96', '-97', -97, '97', RawMap['-98'][5] | '-97', '-'];
        '-96': ['-97', '-95', '-96', -96, '96', RawMap['-97'][5] | '-96', '-'];
        '-95': ['-96', '-94', '-95', -95, '95', RawMap['-96'][5] | '-95', '-'];
        '-94': ['-95', '-93', '-94', -94, '94', RawMap['-95'][5] | '-94', '-'];
        '-93': ['-94', '-92', '-93', -93, '93', RawMap['-94'][5] | '-93', '-'];
        '-92': ['-93', '-91', '-92', -92, '92', RawMap['-93'][5] | '-92', '-'];
        '-91': ['-92', '-90', '-91', -91, '91', RawMap['-92'][5] | '-91', '-'];
        '-90': ['-91', '-89', '-90', -90, '90', RawMap['-91'][5] | '-90', '-'];
        '-89': ['-90', '-88', '-89', -89, '89', RawMap['-90'][5] | '-89', '-'];
        '-88': ['-89', '-87', '-88', -88, '88', RawMap['-89'][5] | '-88', '-'];
        '-87': ['-88', '-86', '-87', -87, '87', RawMap['-88'][5] | '-87', '-'];
        '-86': ['-87', '-85', '-86', -86, '86', RawMap['-87'][5] | '-86', '-'];
        '-85': ['-86', '-84', '-85', -85, '85', RawMap['-86'][5] | '-85', '-'];
        '-84': ['-85', '-83', '-84', -84, '84', RawMap['-85'][5] | '-84', '-'];
        '-83': ['-84', '-82', '-83', -83, '83', RawMap['-84'][5] | '-83', '-'];
        '-82': ['-83', '-81', '-82', -82, '82', RawMap['-83'][5] | '-82', '-'];
        '-81': ['-82', '-80', '-81', -81, '81', RawMap['-82'][5] | '-81', '-'];
        '-80': ['-81', '-79', '-80', -80, '80', RawMap['-81'][5] | '-80', '-'];
        '-79': ['-80', '-78', '-79', -79, '79', RawMap['-80'][5] | '-79', '-'];
        '-78': ['-79', '-77', '-78', -78, '78', RawMap['-79'][5] | '-78', '-'];
        '-77': ['-78', '-76', '-77', -77, '77', RawMap['-78'][5] | '-77', '-'];
        '-76': ['-77', '-75', '-76', -76, '76', RawMap['-77'][5] | '-76', '-'];
        '-75': ['-76', '-74', '-75', -75, '75', RawMap['-76'][5] | '-75', '-'];
        '-74': ['-75', '-73', '-74', -74, '74', RawMap['-75'][5] | '-74', '-'];
        '-73': ['-74', '-72', '-73', -73, '73', RawMap['-74'][5] | '-73', '-'];
        '-72': ['-73', '-71', '-72', -72, '72', RawMap['-73'][5] | '-72', '-'];
        '-71': ['-72', '-70', '-71', -71, '71', RawMap['-72'][5] | '-71', '-'];
        '-70': ['-71', '-69', '-70', -70, '70', RawMap['-71'][5] | '-70', '-'];
        '-69': ['-70', '-68', '-69', -69, '69', RawMap['-70'][5] | '-69', '-'];
        '-68': ['-69', '-67', '-68', -68, '68', RawMap['-69'][5] | '-68', '-'];
        '-67': ['-68', '-66', '-67', -67, '67', RawMap['-68'][5] | '-67', '-'];
        '-66': ['-67', '-65', '-66', -66, '66', RawMap['-67'][5] | '-66', '-'];
        '-65': ['-66', '-64', '-65', -65, '65', RawMap['-66'][5] | '-65', '-'];
        '-64': ['-65', '-63', '-64', -64, '64', RawMap['-65'][5] | '-64', '-'];
        '-63': ['-64', '-62', '-63', -63, '63', RawMap['-64'][5] | '-63', '-'];
        '-62': ['-63', '-61', '-62', -62, '62', RawMap['-63'][5] | '-62', '-'];
        '-61': ['-62', '-60', '-61', -61, '61', RawMap['-62'][5] | '-61', '-'];
        '-60': ['-61', '-59', '-60', -60, '60', RawMap['-61'][5] | '-60', '-'];
        '-59': ['-60', '-58', '-59', -59, '59', RawMap['-60'][5] | '-59', '-'];
        '-58': ['-59', '-57', '-58', -58, '58', RawMap['-59'][5] | '-58', '-'];
        '-57': ['-58', '-56', '-57', -57, '57', RawMap['-58'][5] | '-57', '-'];
        '-56': ['-57', '-55', '-56', -56, '56', RawMap['-57'][5] | '-56', '-'];
        '-55': ['-56', '-54', '-55', -55, '55', RawMap['-56'][5] | '-55', '-'];
        '-54': ['-55', '-53', '-54', -54, '54', RawMap['-55'][5] | '-54', '-'];
        '-53': ['-54', '-52', '-53', -53, '53', RawMap['-54'][5] | '-53', '-'];
        '-52': ['-53', '-51', '-52', -52, '52', RawMap['-53'][5] | '-52', '-'];
        '-51': ['-52', '-50', '-51', -51, '51', RawMap['-52'][5] | '-51', '-'];
        '-50': ['-51', '-49', '-50', -50, '50', RawMap['-51'][5] | '-50', '-'];
        '-49': ['-50', '-48', '-49', -49, '49', RawMap['-50'][5] | '-49', '-'];
        '-48': ['-49', '-47', '-48', -48, '48', RawMap['-49'][5] | '-48', '-'];
        '-47': ['-48', '-46', '-47', -47, '47', RawMap['-48'][5] | '-47', '-'];
        '-46': ['-47', '-45', '-46', -46, '46', RawMap['-47'][5] | '-46', '-'];
        '-45': ['-46', '-44', '-45', -45, '45', RawMap['-46'][5] | '-45', '-'];
        '-44': ['-45', '-43', '-44', -44, '44', RawMap['-45'][5] | '-44', '-'];
        '-43': ['-44', '-42', '-43', -43, '43', RawMap['-44'][5] | '-43', '-'];
        '-42': ['-43', '-41', '-42', -42, '42', RawMap['-43'][5] | '-42', '-'];
        '-41': ['-42', '-40', '-41', -41, '41', RawMap['-42'][5] | '-41', '-'];
        '-40': ['-41', '-39', '-40', -40, '40', RawMap['-41'][5] | '-40', '-'];
        '-39': ['-40', '-38', '-39', -39, '39', RawMap['-40'][5] | '-39', '-'];
        '-38': ['-39', '-37', '-38', -38, '38', RawMap['-39'][5] | '-38', '-'];
        '-37': ['-38', '-36', '-37', -37, '37', RawMap['-38'][5] | '-37', '-'];
        '-36': ['-37', '-35', '-36', -36, '36', RawMap['-37'][5] | '-36', '-'];
        '-35': ['-36', '-34', '-35', -35, '35', RawMap['-36'][5] | '-35', '-'];
        '-34': ['-35', '-33', '-34', -34, '34', RawMap['-35'][5] | '-34', '-'];
        '-33': ['-34', '-32', '-33', -33, '33', RawMap['-34'][5] | '-33', '-'];
        '-32': ['-33', '-31', '-32', -32, '32', RawMap['-33'][5] | '-32', '-'];
        '-31': ['-32', '-30', '-31', -31, '31', RawMap['-32'][5] | '-31', '-'];
        '-30': ['-31', '-29', '-30', -30, '30', RawMap['-31'][5] | '-30', '-'];
        '-29': ['-30', '-28', '-29', -29, '29', RawMap['-30'][5] | '-29', '-'];
        '-28': ['-29', '-27', '-28', -28, '28', RawMap['-29'][5] | '-28', '-'];
        '-27': ['-28', '-26', '-27', -27, '27', RawMap['-28'][5] | '-27', '-'];
        '-26': ['-27', '-25', '-26', -26, '26', RawMap['-27'][5] | '-26', '-'];
        '-25': ['-26', '-24', '-25', -25, '25', RawMap['-26'][5] | '-25', '-'];
        '-24': ['-25', '-23', '-24', -24, '24', RawMap['-25'][5] | '-24', '-'];
        '-23': ['-24', '-22', '-23', -23, '23', RawMap['-24'][5] | '-23', '-'];
        '-22': ['-23', '-21', '-22', -22, '22', RawMap['-23'][5] | '-22', '-'];
        '-21': ['-22', '-20', '-21', -21, '21', RawMap['-22'][5] | '-21', '-'];
        '-20': ['-21', '-19', '-20', -20, '20', RawMap['-21'][5] | '-20', '-'];
        '-19': ['-20', '-18', '-19', -19, '19', RawMap['-20'][5] | '-19', '-'];
        '-18': ['-19', '-17', '-18', -18, '18', RawMap['-19'][5] | '-18', '-'];
        '-17': ['-18', '-16', '-17', -17, '17', RawMap['-18'][5] | '-17', '-'];
        '-16': ['-17', '-15', '-16', -16, '16', RawMap['-17'][5] | '-16', '-'];
        '-15': ['-16', '-14', '-15', -15, '15', RawMap['-16'][5] | '-15', '-'];
        '-14': ['-15', '-13', '-14', -14, '14', RawMap['-15'][5] | '-14', '-'];
        '-13': ['-14', '-12', '-13', -13, '13', RawMap['-14'][5] | '-13', '-'];
        '-12': ['-13', '-11', '-12', -12, '12', RawMap['-13'][5] | '-12', '-'];
        '-11': ['-12', '-10', '-11', -11, '11', RawMap['-12'][5] | '-11', '-'];
        '-10': ['-11', '-9', '-10', -10, '10', RawMap['-11'][5] | '-10', '-'];
        '-9': ['-10', '-8', '-9', -9, '9', RawMap['-10'][5] | '-9', '-'];
        '-8': ['-9', '-7', '-8', -8, '8', RawMap['-9'][5] | '-8', '-'];
        '-7': ['-8', '-6', '-7', -7, '7', RawMap['-8'][5] | '-7', '-'];
        '-6': ['-7', '-5', '-6', -6, '6', RawMap['-7'][5] | '-6', '-'];
        '-5': ['-6', '-4', '-5', -5, '5', RawMap['-6'][5] | '-5', '-'];
        '-4': ['-5', '-3', '-4', -4, '4', RawMap['-5'][5] | '-4', '-'];
        '-3': ['-4', '-2', '-3', -3, '3', RawMap['-4'][5] | '-3', '-'];
        '-2': ['-3', '-1', '-2', -2, '2', RawMap['-3'][5] | '-2', '-'];
        '-1': ['-2', '0', '-1', -1, '1', RawMap['-2'][5] | '-1', '-'];
        '0': ['-1', '1', '0', 0, '0', RawMap['-1'][5] | '0', '0'];
        '1': ['0', '2', '1', 1, '-1', RawMap['0'][5] | '1', '+'];
        '2': ['1', '3', '2', 2, '-2', RawMap['1'][5] | '2', '+'];
        '3': ['2', '4', '3', 3, '-3', RawMap['2'][5] | '3', '+'];
        '4': ['3', '5', '4', 4, '-4', RawMap['3'][5] | '4', '+'];
        '5': ['4', '6', '5', 5, '-5', RawMap['4'][5] | '5', '+'];
        '6': ['5', '7', '6', 6, '-6', RawMap['5'][5] | '6', '+'];
        '7': ['6', '8', '7', 7, '-7', RawMap['6'][5] | '7', '+'];
        '8': ['7', '9', '8', 8, '-8', RawMap['7'][5] | '8', '+'];
        '9': ['8', '10', '9', 9, '-9', RawMap['8'][5] | '9', '+'];
        '10': ['9', '11', '10', 10, '-10', RawMap['9'][5] | '10', '+'];
        '11': ['10', '12', '11', 11, '-11', RawMap['10'][5] | '11', '+'];
        '12': ['11', '13', '12', 12, '-12', RawMap['11'][5] | '12', '+'];
        '13': ['12', '14', '13', 13, '-13', RawMap['12'][5] | '13', '+'];
        '14': ['13', '15', '14', 14, '-14', RawMap['13'][5] | '14', '+'];
        '15': ['14', '16', '15', 15, '-15', RawMap['14'][5] | '15', '+'];
        '16': ['15', '17', '16', 16, '-16', RawMap['15'][5] | '16', '+'];
        '17': ['16', '18', '17', 17, '-17', RawMap['16'][5] | '17', '+'];
        '18': ['17', '19', '18', 18, '-18', RawMap['17'][5] | '18', '+'];
        '19': ['18', '20', '19', 19, '-19', RawMap['18'][5] | '19', '+'];
        '20': ['19', '21', '20', 20, '-20', RawMap['19'][5] | '20', '+'];
        '21': ['20', '22', '21', 21, '-21', RawMap['20'][5] | '21', '+'];
        '22': ['21', '23', '22', 22, '-22', RawMap['21'][5] | '22', '+'];
        '23': ['22', '24', '23', 23, '-23', RawMap['22'][5] | '23', '+'];
        '24': ['23', '25', '24', 24, '-24', RawMap['23'][5] | '24', '+'];
        '25': ['24', '26', '25', 25, '-25', RawMap['24'][5] | '25', '+'];
        '26': ['25', '27', '26', 26, '-26', RawMap['25'][5] | '26', '+'];
        '27': ['26', '28', '27', 27, '-27', RawMap['26'][5] | '27', '+'];
        '28': ['27', '29', '28', 28, '-28', RawMap['27'][5] | '28', '+'];
        '29': ['28', '30', '29', 29, '-29', RawMap['28'][5] | '29', '+'];
        '30': ['29', '31', '30', 30, '-30', RawMap['29'][5] | '30', '+'];
        '31': ['30', '32', '31', 31, '-31', RawMap['30'][5] | '31', '+'];
        '32': ['31', '33', '32', 32, '-32', RawMap['31'][5] | '32', '+'];
        '33': ['32', '34', '33', 33, '-33', RawMap['32'][5] | '33', '+'];
        '34': ['33', '35', '34', 34, '-34', RawMap['33'][5] | '34', '+'];
        '35': ['34', '36', '35', 35, '-35', RawMap['34'][5] | '35', '+'];
        '36': ['35', '37', '36', 36, '-36', RawMap['35'][5] | '36', '+'];
        '37': ['36', '38', '37', 37, '-37', RawMap['36'][5] | '37', '+'];
        '38': ['37', '39', '38', 38, '-38', RawMap['37'][5] | '38', '+'];
        '39': ['38', '40', '39', 39, '-39', RawMap['38'][5] | '39', '+'];
        '40': ['39', '41', '40', 40, '-40', RawMap['39'][5] | '40', '+'];
        '41': ['40', '42', '41', 41, '-41', RawMap['40'][5] | '41', '+'];
        '42': ['41', '43', '42', 42, '-42', RawMap['41'][5] | '42', '+'];
        '43': ['42', '44', '43', 43, '-43', RawMap['42'][5] | '43', '+'];
        '44': ['43', '45', '44', 44, '-44', RawMap['43'][5] | '44', '+'];
        '45': ['44', '46', '45', 45, '-45', RawMap['44'][5] | '45', '+'];
        '46': ['45', '47', '46', 46, '-46', RawMap['45'][5] | '46', '+'];
        '47': ['46', '48', '47', 47, '-47', RawMap['46'][5] | '47', '+'];
        '48': ['47', '49', '48', 48, '-48', RawMap['47'][5] | '48', '+'];
        '49': ['48', '50', '49', 49, '-49', RawMap['48'][5] | '49', '+'];
        '50': ['49', '51', '50', 50, '-50', RawMap['49'][5] | '50', '+'];
        '51': ['50', '52', '51', 51, '-51', RawMap['50'][5] | '51', '+'];
        '52': ['51', '53', '52', 52, '-52', RawMap['51'][5] | '52', '+'];
        '53': ['52', '54', '53', 53, '-53', RawMap['52'][5] | '53', '+'];
        '54': ['53', '55', '54', 54, '-54', RawMap['53'][5] | '54', '+'];
        '55': ['54', '56', '55', 55, '-55', RawMap['54'][5] | '55', '+'];
        '56': ['55', '57', '56', 56, '-56', RawMap['55'][5] | '56', '+'];
        '57': ['56', '58', '57', 57, '-57', RawMap['56'][5] | '57', '+'];
        '58': ['57', '59', '58', 58, '-58', RawMap['57'][5] | '58', '+'];
        '59': ['58', '60', '59', 59, '-59', RawMap['58'][5] | '59', '+'];
        '60': ['59', '61', '60', 60, '-60', RawMap['59'][5] | '60', '+'];
        '61': ['60', '62', '61', 61, '-61', RawMap['60'][5] | '61', '+'];
        '62': ['61', '63', '62', 62, '-62', RawMap['61'][5] | '62', '+'];
        '63': ['62', '64', '63', 63, '-63', RawMap['62'][5] | '63', '+'];
        '64': ['63', '65', '64', 64, '-64', RawMap['63'][5] | '64', '+'];
        '65': ['64', '66', '65', 65, '-65', RawMap['64'][5] | '65', '+'];
        '66': ['65', '67', '66', 66, '-66', RawMap['65'][5] | '66', '+'];
        '67': ['66', '68', '67', 67, '-67', RawMap['66'][5] | '67', '+'];
        '68': ['67', '69', '68', 68, '-68', RawMap['67'][5] | '68', '+'];
        '69': ['68', '70', '69', 69, '-69', RawMap['68'][5] | '69', '+'];
        '70': ['69', '71', '70', 70, '-70', RawMap['69'][5] | '70', '+'];
        '71': ['70', '72', '71', 71, '-71', RawMap['70'][5] | '71', '+'];
        '72': ['71', '73', '72', 72, '-72', RawMap['71'][5] | '72', '+'];
        '73': ['72', '74', '73', 73, '-73', RawMap['72'][5] | '73', '+'];
        '74': ['73', '75', '74', 74, '-74', RawMap['73'][5] | '74', '+'];
        '75': ['74', '76', '75', 75, '-75', RawMap['74'][5] | '75', '+'];
        '76': ['75', '77', '76', 76, '-76', RawMap['75'][5] | '76', '+'];
        '77': ['76', '78', '77', 77, '-77', RawMap['76'][5] | '77', '+'];
        '78': ['77', '79', '78', 78, '-78', RawMap['77'][5] | '78', '+'];
        '79': ['78', '80', '79', 79, '-79', RawMap['78'][5] | '79', '+'];
        '80': ['79', '81', '80', 80, '-80', RawMap['79'][5] | '80', '+'];
        '81': ['80', '82', '81', 81, '-81', RawMap['80'][5] | '81', '+'];
        '82': ['81', '83', '82', 82, '-82', RawMap['81'][5] | '82', '+'];
        '83': ['82', '84', '83', 83, '-83', RawMap['82'][5] | '83', '+'];
        '84': ['83', '85', '84', 84, '-84', RawMap['83'][5] | '84', '+'];
        '85': ['84', '86', '85', 85, '-85', RawMap['84'][5] | '85', '+'];
        '86': ['85', '87', '86', 86, '-86', RawMap['85'][5] | '86', '+'];
        '87': ['86', '88', '87', 87, '-87', RawMap['86'][5] | '87', '+'];
        '88': ['87', '89', '88', 88, '-88', RawMap['87'][5] | '88', '+'];
        '89': ['88', '90', '89', 89, '-89', RawMap['88'][5] | '89', '+'];
        '90': ['89', '91', '90', 90, '-90', RawMap['89'][5] | '90', '+'];
        '91': ['90', '92', '91', 91, '-91', RawMap['90'][5] | '91', '+'];
        '92': ['91', '93', '92', 92, '-92', RawMap['91'][5] | '92', '+'];
        '93': ['92', '94', '93', 93, '-93', RawMap['92'][5] | '93', '+'];
        '94': ['93', '95', '94', 94, '-94', RawMap['93'][5] | '94', '+'];
        '95': ['94', '96', '95', 95, '-95', RawMap['94'][5] | '95', '+'];
        '96': ['95', '97', '96', 96, '-96', RawMap['95'][5] | '96', '+'];
        '97': ['96', '98', '97', 97, '-97', RawMap['96'][5] | '97', '+'];
        '98': ['97', '99', '98', 98, '-98', RawMap['97'][5] | '98', '+'];
        '99': ['98', '100', '99', 99, '-99', RawMap['98'][5] | '99', '+'];
        '100': ['99', '__', '100', 100, '-100', RawMap['99'][5] | '100', '+'];
    };
    /**
     * @hidden
     */
    type MapKeys = {
        '-': '-100' | '-99' | '-98' | '-97' | '-96' | '-95' | '-94' | '-93' | '-92' | '-91' | '-90' | '-89' | '-88' | '-87' | '-86' | '-85' | '-84' | '-83' | '-82' | '-81' | '-80' | '-79' | '-78' | '-77' | '-76' | '-75' | '-74' | '-73' | '-72' | '-71' | '-70' | '-69' | '-68' | '-67' | '-66' | '-65' | '-64' | '-63' | '-62' | '-61' | '-60' | '-59' | '-58' | '-57' | '-56' | '-55' | '-54' | '-53' | '-52' | '-51' | '-50' | '-49' | '-48' | '-47' | '-46' | '-45' | '-44' | '-43' | '-42' | '-41' | '-40' | '-39' | '-38' | '-37' | '-36' | '-35' | '-34' | '-33' | '-32' | '-31' | '-30' | '-29' | '-28' | '-27' | '-26' | '-25' | '-24' | '-23' | '-22' | '-21' | '-20' | '-19' | '-18' | '-17' | '-16' | '-15' | '-14' | '-13' | '-12' | '-11' | '-10' | '-9' | '-8' | '-7' | '-6' | '-5' | '-4' | '-3' | '-2' | '-1';
        '0': '0';
        '+': '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9' | '10' | '11' | '12' | '13' | '14' | '15' | '16' | '17' | '18' | '19' | '20' | '21' | '22' | '23' | '24' | '25' | '26' | '27' | '28' | '29' | '30' | '31' | '32' | '33' | '34' | '35' | '36' | '37' | '38' | '39' | '40' | '41' | '42' | '43' | '44' | '45' | '46' | '47' | '48' | '49' | '50' | '51' | '52' | '53' | '54' | '55' | '56' | '57' | '58' | '59' | '60' | '61' | '62' | '63' | '64' | '65' | '66' | '67' | '68' | '69' | '70' | '71' | '72' | '73' | '74' | '75' | '76' | '77' | '78' | '79' | '80' | '81' | '82' | '83' | '84' | '85' | '86' | '87' | '88' | '89' | '90' | '91' | '92' | '93' | '94' | '95' | '96' | '97' | '98' | '99' | '100';
    };
    /**
    Describes a map of number relationships
    */
    export type NumberMap = CreateMap<MapKeys, RawMap>;
}
declare module "Iteration/Next" {
    import { Map } from "Iteration/Map";
    import { Iteration } from "Iteration/Iteration";
    import { NumberMap } from "Iteration/Maps/Number";
    /**
    Move **`I`**'s position forward
    @param I to move
    @param IMap to operate with another set of numbers
    @returns [[Iteration]]
    @example
    ```ts
    import {I} from 'ts-toolbelt'
    
    type i = I.IterationOf<'20'>
    
    type test0 = I.Pos<i>         // 20
    type test1 = I.Pos<I.Next<i>> // 21
    ```
    */
    export type Next<I extends Iteration, IMap extends Map = NumberMap> = IMap[1][I[1]];
}
declare module "List/List" {
    /**
    A [[List]]
    @param A its type
    @returns [[List]]
    @example
    ```ts
    type list0 = [1, 2, 3]
    type list1 = number[]
    ```
    */
    export type List<A = any> = ReadonlyArray<A>;
}
declare module "List/Prepend" {
    import { List } from "List/List";
    /**
    Add an element **`A`** at the beginning of **`L`**
    @param L to append to
    @param A to be added to
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Prepend<L extends List, A extends any> = ((head: A, ...args: L) => any) extends ((...args: infer U) => any) ? U : L;
}
declare module "Number/Number" {
    /**
    A [[Number]]
    @example
    ```ts
    type number0 = '-42`
    type number1 = '420'
    ```
    */
    export type Number = string;
}
declare module "Iteration/IterationOf" {
    import { Number } from "Number/Number";
    import { NumberMap } from "Iteration/Maps/Number";
    import { Map } from "Iteration/Map";
    /**
    Transform a number into an [[Iteration]]
    (to use [[Prev]], [[Next]], & [[Pos]])
    @param N to transform
    @param IMap to operate with another set of numbers
    @returns [[Iteration]]
    @example
    ```ts
    import {I} from 'ts-toolbelt'
    
    type i = I.IterationOf<'0'> // ["-1", "1", "0", 0, "0"]
    
    type next = I.Next<i>       // ["0", "2", "1", 1, "+"]
    type prev = I.Prev<i>       // ["-2", "0", "-1", -1, "-"]
    
    type nnext = I.Pos<next>    // +1
    type nprev = I.Pos<prev>    // -1
    ```
    */
    export type IterationOf<N extends Number, IMap extends Map = NumberMap> = N extends keyof IMap[1] ? IMap[1][N] : IMap[1]['__'];
}
declare module "Any/Cast" {
    /**
     * Ask TS to re-check that **`A1`** extends **`A2`**.
     * And if it fails, **`A2`** will be enforced anyway.
     * Can also be used to add constraints on parameters.
     * @param A1 to check against
     * @param A2 to cast **`A1`** to
     * @returns **`A1`** or **`A2`**
     * @example
     * ```ts
     * import {A} from 'ts-toolbelt'
     *
     * type test0 = A.Cast<'42', string> // '42'
     * type test1 = A.Cast<'42', number> // number
     * ```
     */
    export type Cast<A1 extends any, A2 extends any> = A1 extends A2 ? A1 : A2;
}
declare module "Iteration/_Internal" {
    /**
    Describes compatible type formats
    * `s`: **`string`**
    * `n`: **`number`**
    */
    export type Formats = 'n' | 's';
    /**
    Describes how to perform iterations
    */
    export type Way = '->' | '<-';
}
declare module "Iteration/Format" {
    import { Iteration } from "Iteration/Iteration";
    import { Formats } from "Iteration/_Internal";
    /**
    Is [[Key]] and [[Pos]] in a single type
    @param I to query
    @param fmt output format
    @returns **`string | number`**
    @example
    ```ts
    import {I} from 'ts-toolbelt'
    
    /// Let's make '20' an iteration
    type i = I.IterationOf<'20'> // [...]
    
    type fmtS = I.Fmt<i, 's'> // '20'
    type fmtN = I.Fmt<i, 'n'> //  20
    ```
    */
    export type Format<I extends Iteration, fmt extends Formats> = {
        's': I[2];
        'n': I[3];
    }[fmt];
}
declare module "Iteration/Key" {
    import { Iteration } from "Iteration/Iteration";
    import { Format } from "Iteration/Format";
    /**
    Get the position of **`I`** (**string**)
    @param I to query
    @returns [[String]]
    @example
    ```ts
    import {I} from 'ts-toolbelt'
    
    type i = I.IterationOf<'20'>
    
    type test0 = I.Key<i>         // '20'
    type test1 = I.Key<I.Next<i>> // '21'
    ```
    */
    export type Key<I extends Iteration> = Format<I, 's'>;
}
declare module "Any/Extends" {
    /**
     * Check whether **`A1`** is part of **`A2`** or not. The difference with
     * `extends` is that it forces a [[Boolean]] return.
     * @param A1
     * @param A2
     * @returns [[Boolean]]
     * @example
     * ```ts
     * import {A} from 'ts-toolbelt'
     *
     * type test0 = A.Extends<'a' | 'b', 'b'> // Boolean
     * type test1 = A.Extends<'a', 'a' | 'b'> // True
     *
     * type test2 = A.Extends<{a: string}, {a: any}>      // True
     * type test3 = A.Extends<{a: any}, {a: any, b: any}> // False
     *
     * type test4 = A.Extends<never, never> // False
     * /// Nothing cannot extend nothing, use `A.Equals`
     * ```
     */
    export type Extends<A1 extends any, A2 extends any> = [
        A1
    ] extends [never] ? 0 : A1 extends A2 ? 1 : 0;
}
declare module "List/Repeat" {
    import { Next } from "Iteration/Next";
    import { Prepend } from "List/Prepend";
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Number } from "Number/Number";
    import { Cast } from "Any/Cast";
    import { Key } from "Iteration/Key";
    import { List } from "List/List";
    import { Extends } from "Any/Extends";
    /**
    @hidden
    */
    type __Repeat<N extends Number, A, L extends List = [], I extends Iteration = IterationOf<'0'>> = {
        0: __Repeat<N, A, Prepend<L, A>, Next<I>>;
        1: L;
    }[Extends<Key<I>, N>];
    /**
    @hidden
    */
    export type _Repeat<A extends any, N extends Number, L extends List = []> = __Repeat<N, A, L> extends infer X ? Cast<X, List> : never;
    /**
    Fill a [[List]] with **`N`** times **`A`**
    @param A to fill with
    @param N to repeat it
    @param L (?=`[]`) to be filled
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Repeat<A extends any, N extends Number, L extends List = []> = N extends unknown ? L extends unknown ? _Repeat<A, N, L> : never : never;
}
declare module "Any/Equals" {
    /**
     * Check whether **`A1`** is equal to **`A2`** or not.
     * @param A1
     * @param A2
     * @returns [[Boolean]]
     * @example
     * ```ts
     * import {A} from 'ts-toolbelt'
     *
     * type test0 = A.Equals<42 | 0, 42 | 0>                    // true
     * type test1 = A.Equals<{a: string}, {b: string}>          // false
     * type test3 = A.Equals<{a: string}, {readonly a: string}> // false
     * ```
     */
    export type Equals<A1 extends any, A2 extends any> = (<A>() => A extends A2 ? 1 : 0) extends (<A>() => A extends A1 ? 1 : 0) ? 1 : 0;
}
declare module "Object/_Internal" {
    /**
    Describes the permissions/modifiers fields can have
    * `R`: readonly
    * `W`: writable
    * `!`: required
    * `?`: optional
    */
    export type Modx = ['?' | '!', 'W' | 'R'];
    /**
    Describes the depth strategy when modifying types
    */
    export type Depth = 'flat' | 'deep';
    /**
     * Describes the merging strategy
     * `0`: lodash style. Preserves lists, and completes when undefined types
     * `1`: ramda style. Destroys lists, does not complete if undefined types
     * `2`: lodash style. Lists are narrowed down, tuples are not preserved
     * `3`: ramda style. Assumes that we are only working with lists
     */
    export type MergeStyle = 0 | 1 | 2;
    /**
    Make an object properties (all) `never`. We use this to intersect `object`s and
    preserve the combine modifiers like `+readonly` and `?optional`.
     */
    export type Anyfy<O extends object> = {
        [K in keyof O]: any;
    } & {};
}
declare module "Misc/BuiltInObject" {
    /**
     * @hidden
     */
    type Errors = Error;
    /**
     * @hidden
     */
    type Numeric = Date;
    /**
     * @hidden
     */
    type Textual = RegExp;
    /**
     * @hidden
     */
    type Arrays = Int8Array | Uint8Array | Uint8ClampedArray | Int16Array | Uint16Array | Int32Array | Uint32Array | Float32Array | Float64Array;
    /**
     * @hidden
     */
    type Maps = ReadonlyMap<unknown, unknown> | ReadonlySet<unknown> | WeakMap<object, unknown> | WeakSet<object>;
    /**
     * @hidden
     */
    type Structures = ArrayBuffer | DataView;
    /**
     * @hidden
     */
    type Abstractions = Function | Promise<unknown> | Generator;
    /**
     * @hidden
     */
    type WebAssembly = never;
    /**
     * Built-in standard library objects
     */
    export type BuiltInObject = Errors | Numeric | Textual | Arrays | Maps | Structures | Abstractions | WebAssembly;
}
declare module "Any/Compute" {
    import { Depth } from "Object/_Internal";
    import { BuiltInObject } from "Misc/BuiltInObject";
    /**
     * @hidden
     */
    export type ComputeRaw<A extends any> = A extends Function ? A : {
        [K in keyof A]: A[K];
    } & {};
    /**
     * @hidden
     */
    export type ComputeFlat<A extends any> = A extends BuiltInObject ? A : {
        [K in keyof A]: A[K];
    } & {};
    /**
     * @hidden
     */
    export type ComputeDeep<A extends any, Seen extends any = A> = A extends BuiltInObject ? A : {
        [K in keyof A]: A[K] extends Seen ? A[K] : ComputeDeep<A[K], A[K] | Seen>;
    } & {};
    /**
     * Force TS to load a type that has not been computed (to resolve composed
     * types that TS haven't fully resolved, for display purposes mostly).
     * @param A to compute
     * @returns **`A`**
     * @example
     * ```ts
     * import {A} from 'ts-toolbelt'
     *
     * type test0 = A.Compute<{x: 'x'} & {y: 'y'}> // {x: 'x', y: 'y'}
     * ```
     */
    export type Compute<A extends any, depth extends Depth = 'deep'> = {
        'flat': ComputeFlat<A>;
        'deep': ComputeDeep<A>;
    }[depth];
}
declare module "Boolean/Boolean" {
    /**
    A [[Boolean]]
    */
    export type Boolean = True | False;
    /**
    1
    */
    export type True = 1;
    /**
    0
    */
    export type False = 0;
}
declare module "Test" {
    import { Repeat } from "List/Repeat";
    import { Equals } from "Any/Equals";
    import { ComputeRaw } from "Any/Compute";
    import { True, False, Boolean } from "Boolean/Boolean";
    /**
    Test should pass
    */
    export type Pass = True;
    /**
    Test should fail
    */
    export type Fail = False;
    /**
    Check or test the validity of a type
    @param debug to debug with parameter hints (`ctrl+p`, `ctrl+shift+space`)
    @example
    ```ts
    // see in `tst` folder
    ```
    */
    export function check<Type, Expect, Outcome extends Boolean>(debug?: ComputeRaw<Type>): Equals<Equals<Type, Expect>, Outcome>;
    /**
    Validates a batch of [[check]]
    @param checks a batch of [[check]]
    @example
    ```ts
    // see in `tst` folder
    ```
    */
    export function checks(checks: Partial<Repeat<Pass, '30'>>): void;
}
declare module "Any/Key" {
    /**
     * Describes index keys for any type
     */
    export type Key = string | number | symbol;
}
declare module "Object/Pick" {
    import { Key } from "Any/Key";
    /**
    @hidden
    */
    type __Pick<O extends object, K extends keyof O> = {
        [P in K]: O[P];
    } & {};
    /**
    @hidden
    */
    export type _Pick<O extends object, K extends Key> = __Pick<O, keyof O & K>;
    /**
    Extract out of **`O`** the fields of key **`K`**
    @param O to extract from
    @param K to chose fields
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Pick<O extends object, K extends Key> = O extends unknown ? _Pick<O, K> : never;
}
declare module "Union/Union" {
    /**
    A [[Union]]
    @example
    ```ts
    type union0 = 1 | 2 | 3
    type union1 = 'a' | 420
    ```
    */
    export type Union = any;
}
declare module "Union/Exclude" {
    import { Union } from "Union/Union";
    /**
    Remove **`M`** out of **`U`**
    @param U to remove from
    @param M to remove out
    @returns [[Union]]
    @example
    ```ts
    ```
    */
    export type Exclude<U extends Union, M extends Union> = U extends M ? never : U;
}
declare module "Object/Omit" {
    import { _Pick } from "Object/Pick";
    import { Exclude } from "Union/Exclude";
    import { Key } from "Any/Key";
    /**
     * @hidden
     */
    export type _Omit<O extends object, K extends Key> = _Pick<O, Exclude<keyof O, K>>;
    /**
    Remove out of **`O`** the fields of key **`K`**
    @param O to remove from
    @param K to chose fields
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Omit<O extends object, K extends Key> = O extends unknown ? _Omit<O, K> : never;
}
declare module "Object/At" {
    import { Key } from "Any/Key";
    import { Boolean } from "Boolean/Boolean";
    /**
    @hidden
    */
    export type AtBasic<O extends object, K extends Key> = K extends keyof O ? O[K] : never;
    /**
    @hidden
    */
    export type AtStrict<O extends object, K extends Key> = O[K & keyof O];
    /**
    @hidden
    */
    export type AtLoose<O extends object, K extends Key> = O extends unknown ? AtStrict<O, K> : never;
    /**
    Get in **`O`** the type of a field of key **`K`**
    @param O to extract from
    @param K to extract at
    @param strict (?=`1`) `0` to work with unions
    @returns **`any`**
    @example
    ```ts
    import {O} from 'ts-toolbelt'
    
    type User = {
        info: {
            name: string
            age: number
            payment: {}
        }
        id: number
    }
    
    type test0 = O.At<User, 'id'> // number
    ```
    */
    export type At<O extends object, K extends Key, strict extends Boolean = 1> = {
        1: AtStrict<O, K>;
        0: AtLoose<O, K>;
    }[strict];
}
declare module "Number/_Internal" {
    import { Format } from "Iteration/Format";
    import { Map } from "Iteration/Map";
    import { NumberMap } from "Iteration/Maps/Number";
    /**
    Describes compatible type formats
    * `b`: **`boolean`**
    * `n`: **`number`**
    * `s`: **`string`**
    */
    export type Formats = 'b' | 'n' | 's';
    /**
     * @hidden
     */
    export type KnownIterationMapKeys<IMap extends Map> = IMap[0]['-' | '0' | '+'];
    /**
     * @hidden
     */
    export type NegativeIterationKeys<IMap extends Map> = IMap[0]['-'];
    /**
     * @hidden
     */
    export type PositiveIterationKeys<IMap extends Map> = IMap[0]['+'];
    /**
     * @hidden
     */
    export type NeutralIterationKeys<IMap extends Map> = IMap[0]['0'];
    /**
    Describes known values of a **number**
    @hidden
    */
    export type Numbers<IMap extends Map = NumberMap> = {
        'string': {
            'all': Format<IMap[1][KnownIterationMapKeys<IMap>], 's'>;
            '+': Format<IMap[1][PositiveIterationKeys<IMap>], 's'>;
            '-': Format<IMap[1][NegativeIterationKeys<IMap>], 's'>;
            '0': Format<IMap[1][NeutralIterationKeys<IMap>], 's'>;
        };
        'number': {
            'all': Format<IMap[1][KnownIterationMapKeys<IMap>], 'n'>;
            '+': Format<IMap[1][PositiveIterationKeys<IMap>], 'n'>;
            '-': Format<IMap[1][NegativeIterationKeys<IMap>], 'n'>;
            '0': Format<IMap[1][NeutralIterationKeys<IMap>], 'n'>;
        };
    };
}
declare module "Iteration/Pos" {
    import { Iteration } from "Iteration/Iteration";
    import { Format } from "Iteration/Format";
    /**
    Get the position of **`I`** (**number**)
    @param I to query
    @param IMap to operate with another set of numbers
    @returns **`number`**
    @example
    ```ts
    import {I} from 'ts-toolbelt'
    
    type i = I.IterationOf<'20'>
    
    type test0 = I.Pos<i>         // 20
    type test1 = I.Pos<I.Next<i>> // 21
    ```
    */
    export type Pos<I extends Iteration> = Format<I, 'n'>;
}
declare module "Number/NumberOf" {
    import { Key } from "Iteration/Key";
    import { Pos } from "Iteration/Pos";
    import { Numbers, KnownIterationMapKeys } from "Number/_Internal";
    import { NumberMap } from "Iteration/Maps/Number";
    import { Map } from "Iteration/Map";
    /**
    @hidden
    */
    export type _NumberOf<N extends number, IMap extends Map> = {
        [K in keyof IMap[1]]: Pos<IMap[1][K]> extends N ? Key<IMap[1][K]> : never;
    }[KnownIterationMapKeys<IMap>];
    /**
    Transform a **`number`** into a [[Number]]
    @param N to stringify
    @param IMap to operate with another set of numbers
    @returns [[String]]
    @example
    ```ts
    import {N} from 'ts-toolbelt'
    
    type test0 = N.StringOf<5>  //  '5'
    type test1 = N.StringOf<-5> // '-5'
    ```
    */
    export type NumberOf<N extends number, IMap extends Map = NumberMap> = N extends Numbers<IMap>['number']['all'] ? _NumberOf<N, IMap> : string;
}
declare module "List/Length" {
    import { NumberOf } from "Number/NumberOf";
    import { Formats } from "Iteration/_Internal";
    import { List } from "List/List";
    /**
    Get the length of **`L`**
    @param L to get length
    @param fmt (?=`'n'`) output format
    @returns [[String]] or **`number`**
    @example
    ```ts
    ```
    */
    export type Length<L extends List, fmt extends Formats = 'n'> = {
        's': NumberOf<L['length']>;
        'n': L['length'];
    }[fmt];
}
declare module "Object/Overwrite" {
    /**
    Update the fields of **`O`** with the ones of **`O1`**
    (only the existing fields will be updated)
    @param O to update
    @param O1 to update with
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Overwrite<O extends object, O1 extends object> = {
        [K in keyof O]: K extends keyof O1 ? O1[K] : O[K];
    } & {};
}
declare module "List/_Internal" {
    /** @ignore */ /** */
    import { Overwrite } from "Object/Overwrite";
    import { List } from "List/List";
    /**
    Remove `?` & `readonly` from a [[List]]
     */
    export type Naked<L extends List> = Overwrite<Required<L>, L>;
}
declare module "List/Reverse" {
    import { Prepend } from "List/Prepend";
    import { Pos } from "Iteration/Pos";
    import { Next } from "Iteration/Next";
    import { Length } from "List/Length";
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Cast } from "Any/Cast";
    import { List } from "List/List";
    import { Naked } from "List/_Internal";
    import { Extends } from "Any/Extends";
    /**
    @hidden
    */
    type __Reverse<L extends List, LO extends List, I extends Iteration = IterationOf<'0'>> = {
        0: __Reverse<L, Prepend<LO, L[Pos<I>]>, Next<I>>;
        1: LO;
    }[Extends<Pos<I>, Length<L>>];
    /**
    @hidden
    */
    export type _Reverse<L extends List, LO extends List = []> = __Reverse<Naked<L>, LO> extends infer X ? Cast<X, List> : never;
    /**
    Turn a [[List]] the other way around
    @param L to reverse
    @param LO (?=`[]`) to prepend to
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Reverse<L extends List, LO extends List = []> = L extends unknown ? LO extends unknown ? _Reverse<L, LO> : never : never;
}
declare module "List/Concat" {
    import { _Reverse } from "List/Reverse";
    import { List } from "List/List";
    /**
    @hidden
    */
    export type _Concat<L extends List, L1 extends List> = _Reverse<_Reverse<L>, L1>;
    /**
    Attach **`L1`** at the end of **`L`**
    @param L to concat with
    @param L1 to be attached
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Concat<L extends List, L1 extends List> = L extends unknown ? L1 extends unknown ? _Concat<L, L1> : never : never;
}
declare module "List/Append" {
    import { _Concat } from "List/Concat";
    import { List } from "List/List";
    /**
    @hidden
    */
    export type _Append<L extends List, A extends any> = _Concat<L, [A]>;
    /**
    Add an element **`A`** at the end of **`L`**
    @param L to append to
    @param A to be added to
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Append<L extends List, A extends any> = L extends unknown ? A extends unknown ? _Append<L, A> : never : never;
}
declare module "Object/ListOf" {
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Key } from "Iteration/Key";
    import { Next } from "Iteration/Next";
    import { _Append } from "List/Append";
    import { Exclude } from "Union/Exclude";
    import { List } from "List/List";
    import { Extends } from "Any/Extends";
    import { At } from "Object/At";
    /**
    @hidden
    */
    type PickIfEntry<O extends object, LN extends List, I extends Iteration> = Key<I> extends keyof O ? _Append<LN, O[Key<I> & keyof O]> : LN;
    /**
    @hidden
    */
    type ___ListOf<O extends object, K, LN extends List = [], I extends Iteration = IterationOf<'0'>> = {
        0: ___ListOf<O, Exclude<K, Key<I>>, PickIfEntry<O, LN, I>, Next<I>>;
        1: LN;
    }[Extends<[K], [never]>];
    /**
    @hidden
    */
    type __ListOf<O extends object> = number extends keyof O ? At<O, number>[] : string extends keyof O ? At<O, string>[] : symbol extends keyof O ? At<O, symbol>[] : ___ListOf<O, keyof O>;
    /**
    @hidden
    */
    export type _ListOf<O extends object> = __ListOf<O>;
    /**
    Transform an [[Object]] into a [[List]]
    (It will only pick numeric literal indexes)
    @param O to transform
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type ListOf<O extends object> = O extends unknown ? _ListOf<O> : never;
}
declare module "Boolean/Not" {
    import { Boolean } from "Boolean/Boolean";
    /**
    Logical **`!`** operator (behaves like the JS one)
    @param B to negate
    @returns [[Boolean]]
    @example
    ```ts
    import {B} from 'ts-toolbelt'
    
    type test0 = B.Not<B.True>  // False
    type test1 = B.Not<B.False> // True
    ```
    */
    export type Not<B extends Boolean> = {
        0: 1;
        1: 0;
    }[B];
}
declare module "Union/Has" {
    import { Union } from "Union/Union";
    import { Not } from "Boolean/Not";
    import { Extends } from "Any/Extends";
    /**
    Check whether **`U`** contains **`U1`**
    @param U to be inspected
    @param U1 to check within
    @returns [[Boolean]]
    @example
    ```ts
    ```
    */
    export type Has<U extends Union, U1 extends Union> = Not<Extends<Exclude<U1, U>, U1>>;
}
declare module "Any/Clean" {
    import { _Omit } from "Object/Omit";
    import { _Pick } from "Object/Pick";
    import { At } from "Object/At";
    import { Exclude } from "Union/Exclude";
    import { Numbers } from "Number/_Internal";
    import { _ListOf } from "Object/ListOf";
    import { Has } from "Union/Has";
    /**
     * @hidden
     */
    type ArrayEntry = Numbers['string']['0' | '+'];
    /**
     * @hidden
     */
    type ArrayProps = keyof any[] | ArrayEntry;
    /**
     * Sometimes, we can end up with mixed up **`objects`** that do not make sense
     * visually (or that could at least be simplified for the end user). This will
     * turn anything that is passed to it into a cleaned up [[Object]].
     *
     * @param O
     * @returns [[Object]]
     * @example
     * ```ts
     * ```
     */
    export type Clean<A extends any> = A extends object ? Has<keyof A, keyof any[]> extends 1 ? [Exclude<keyof A, ArrayProps>] extends [never] ? number extends At<A, 'length'> ? At<A, number>[] : A : number extends At<A, 'length'> ? _Omit<A, ArrayProps> & At<A, number>[] : At<A, 'length'> extends number ? _Omit<A, ArrayProps> & _ListOf<_Pick<A, ArrayEntry>> : A : A : A;
}
declare module "Any/Contains" {
    import { Extends } from "Any/Extends";
    /**
     * Check whether **`A1`** is part of **`A2`** or not. It works like
     * [[Extends]] but [[Boolean]] results are narrowed to [[False]].
     * @param A1
     * @param A2
     * @returns [[Boolean]]
     * @example
     * ```ts
     * type test0 = A.Contains<'a' | 'b', 'b'> // False
     * type test1 = A.Contains<'a', 'a' | 'b'> // True
     *
     * type test2 = A.Contains<{a: string}, {a: string, b: number}> // False
     * type test3 = A.Contains<{a: string, b: number}, {a: string}> // True
     *
     * type test4 = A.Contains<never, never> // False
     * /// Nothing cannot contain nothing, use `A.Equals`
     * ```
     */
    export type Contains<A1 extends any, A2 extends any> = Extends<A1, A2> extends 1 ? 1 : 0;
}
declare module "Any/_Internal" {
    import { _NumberOf } from "Number/NumberOf";
    import { NumberMap } from "Iteration/Maps/Number";
    /**
     * Describes the match strategy when matching types
     * * `default`     : `extends->`
     * * `contains->`  : X contains   Y ([[Contains]]<X, Y>)
     * * `extends->`   : X extends    Y ([[Extends]]<X, Y>)
     * * `implements->`: X implements Y ([[Implements]]<X, Y>)
     * * `<-contains`  : Y contains   X ([[Contains]]<Y, X>)
     * * `<-extends`   : Y extends    X ([[Extends]]<Y, X>)
     * * `<-implements`: Y implements X ([[Implements]]<Y, X>)
     * * `equals`      : X equals     Y (([[Equals]]<X, Y>))
     */
    export type Match = 'default' | 'contains->' | 'extends->' | 'implements->' | '<-contains' | '<-extends' | '<-implements' | 'equals';
    /**
     * @hidden
     */
    export type NumberOf<N extends any> = N extends number ? _NumberOf<N, NumberMap> : N;
    /**
     * @hidden
     */
    export type _Promise<A extends any> = Promise<A>;
}
declare module "Any/Is" {
    import { Match } from "Any/_Internal";
    import { Extends } from "Any/Extends";
    import { Equals } from "Any/Equals";
    import { Contains } from "Any/Contains";
    /**
     * Check whether **`A`** is similar to **`A1`** or not. In other words, it is a
     * compact type that bundles [[Equals]], [[Extends]], [[Contains]], and
     * [[Implements]] comparison types.
     * @param A to be compared
     * @param A1 to compare to
     * @param match (?=`'default'`) to change precision
     * @returns [[Boolean]]
     * @example
     * ```ts
     * import {A} from 'ts-toolbelt'
     *
     * type test0 = A.Is<'a', 'a' | 'b', 'extends->'> // True
     * type test1 = A.Is<'a' | 'b', 'a', 'extends->'> // Boolean
     *
     * type test2 = A.Is<'a', 'a' | 'b', '<-extends'> // Boolean
     * type test3 = A.Is<'a' | 'b', 'a', '<-extends'> // True
     *
     * type test4 = A.Is<'a', 'a' | 'b', 'implements->'> // True
     * type test5 = A.Is<'a' | 'b', 'a', 'implements->'> // False
     *
     * type test6 = A.Is<'a', 'a' | 'b', '<-implements'> // False
     * type test7 = A.Is<'a' | 'b', 'a', '<-implements'> // True
     *
     * type test8 = A.Is<'a', 'a' | 'b', 'equals'>      // False
     * type test9 = A.Is<'b' |'a', 'a' | 'b', 'equals'> // True
     * ```
     */
    export type Is<A extends any, A1 extends any, match extends Match = 'default'> = {
        'default': Extends<A, A1>;
        'contains->': Contains<A, A1>;
        'extends->': Extends<A, A1>;
        'implements->': Contains<A, A1>;
        '<-contains': Contains<A1, A>;
        '<-extends': Extends<A1, A>;
        '<-implements': Contains<A1, A>;
        'equals': Equals<A1, A>;
    }[match];
}
declare module "Boolean/And" {
    import { Boolean } from "Boolean/Boolean";
    /**
    Logical **`&&`** operator (behaves like the JS one)
    @param B1 Left-hand side
    @param B2 Right-hand side
    @returns [[Boolean]]
    @example
    ```ts
    import {B} from 'ts-toolbelt'
    
    type test0 = B.And<B.True, B.False>          // False
    type test1 = B.And<B.True, B.True>           // True
    type test2 = B.And<B.True | B.False, B.True> // Boolean
    ```
    */
    export type And<B1 extends Boolean, B2 extends Boolean> = {
        0: {
            0: 0;
            1: 0;
        };
        1: {
            0: 0;
            1: 1;
        };
    }[B1][B2];
}
declare module "Boolean/Or" {
    import { Boolean } from "Boolean/Boolean";
    /**
    Logical **`||`** operator (behaves like the JS one)
    @param B1 Left-hand side
    @param B2 Right-hand side
    @returns [[Boolean]]
    @example
    ```ts
    import {B} from 'ts-toolbelt'
    
    type test0 = B.Or<B.True, B.False>    // True
    type test1 = B.Or<B.True, B.True>     // True
    type test2 = B.Or<B.Boolean, B.False> // Boolean
    ```
    */
    export type Or<B1 extends Boolean, B2 extends Boolean> = {
        0: {
            0: 0;
            1: 1;
        };
        1: {
            0: 1;
            1: 1;
        };
    }[B1][B2];
}
declare module "Any/IsLiteral" {
    import { And } from "Boolean/And";
    import { Or } from "Boolean/Or";
    import { Extends } from "Any/Extends";
    /**
     * @hidden
     */
    export type IsStringLiteral<A extends any> = A extends string ? string extends A ? 0 : 1 : 0;
    /**
     * @hidden
     */
    export type IsNumberLiteral<A extends any> = A extends number ? number extends A ? 0 : 1 : 0;
    /**
     * Literal to restrict against
     */
    export type Kind = string | number;
    /**
     * Determine whether **`A`** is literal or not
     * @param A to be checked
     * @param kind (?=`'string' | 'number'`) to restrict
     * @example
     * ```ts
     * import {A} from 'ts-toolbelt'
     *
     * type test0 = A.IsLiteral<1 | 2> // 1
     * type test1 = A.IsLiteral<1 | 2, string> // 0
     * type test2 = A.IsLiteral<1 | '2', string> // 0 | 1
     * type test3 = A.IsLiteral<number> // 0
     * ```
     */
    export type IsLiteral<A extends any, kind extends Kind = Kind> = And<Or<IsStringLiteral<A>, IsNumberLiteral<A>>, Extends<A, kind>>;
}
declare module "Any/Kind" {
    import { Extends } from "Any/Extends";
    import { List } from "List/List";
    /**
     * @hidden
     */
    type _Kind<A extends any> = Extends<A, Function> extends 1 ? 'function' : Extends<A, List> extends 1 ? 'array' : Extends<A, object> extends 1 ? 'object' : Extends<A, string> extends 1 ? 'string' : Extends<A, number> extends 1 ? 'number' : Extends<A, boolean> extends 1 ? 'boolean' : 'unknown';
    /**
     * Get the literal kind of a type
     * @param A
     * @returns **`'string' | 'number' | 'function' | 'array' | 'object' | 'boolean' | 'unknown'`**
     * @example
     * ```ts
     * ```
     */
    export type Kind<A extends any> = A extends unknown ? _Kind<A> : never;
}
declare module "Any/Promise" {
    /**
     * Create an asynchronous operation like the original `Promise` type but this
     * one prevents promises to be wrapped within more promises (not possible).
     * @param A
     */
    export type Promise<A extends any> = globalThis.Promise<A extends globalThis.Promise<infer X> ? X : A>;
}
declare module "Any/Promisable" {
    import { Promise } from "Any/Promise";
    /**
     * A way to say that you can handle **`Promises`** and non-**`Promises`**. This
     * is often the case if you're a heavy user of `await` and `async`.
     * @param A **`A`** A type
     * @returns **`A | Promise<A>`**
     * @example
     */
    export type Promisable<A extends any> = A | Promise<A>;
}
declare module "Any/PromiseOf" {
    /**
    Get the instance type wrapped within a **`Promise`**
    @param P **`Promise`**
    @returns **`any`**
    @example
    ```ts
    import {C} from 'ts-toolbelt'
    
    const promise = new Promise<string>((res, rej) => res('x'))
    
    type test0 = C.PromiseOf<typeof promise>  // string
    type test1 = C.PromiseOf<Promise<number>> // number
    ```
    */
    export type PromiseOf<P extends any> = P extends Promise<infer A> ? A : P;
}
declare module "Any/Try" {
    /**
     * Similar to [[Cast]] but with a custom fallback **`Catch`**. If it fails,
     * it will enforce **`Catch`** instead of **`A2`**.
     * @param A1 to check against
     * @param A2 to try **`A1`** with
     * @param Catch to fallback (fail)
     * @returns **`A1`** or **`Catch`**
     * @example
     * ```ts
     * import {A} from 'ts-toolbelt'
     *
     * type test0 = A.Try<'42', string>          // '42'
     * type test1 = A.Try<'42', number>          // never
     * type test1 = A.Try<'42', number, 'tried'> // 'tried'
     * ```
     */
    export type Try<A1 extends any, A2 extends any, Catch = never> = A1 extends A2 ? A1 : Catch;
}
declare module "Any/Type" {
    import { Key } from "Any/Key";
    /**
     * Create your own opaque sub-type from a type **`A`**
     * @param A to be personalized
     * @param Id to name the sub-type
     * @returns A new type **`Type<A, Id>`**
     * @example
     * ```ts
     * import {A} from 'ts-toolbelt'
     *
     * type EUR = Type<number, 'eur'>
     * type USD = Type<number, 'usd'>
     *
     * let eurWallet = 10 as EUR
     * let usdWallet = 15 as USD
     *
     * eurWallet = usdWallet // error
     * ```
     */
    export type Type<A extends any, Id extends Key> = A & {
        __type__: Id;
    };
}
declare module "Any/x" {
    import { Type } from "Any/Type";
    /**
     * A placeholder that is used in various ways
     */
    export type x = Type<{}, 'x'>;
}
declare module "List/ObjectOf" {
    import { _Omit } from "Object/Omit";
    import { _Pick } from "Object/Pick";
    import { List } from "List/List";
    /**
    Transform a [[List]] into an [[Object]] equivalent
    @param L to transform
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type ObjectOf<O extends object> = O extends List ? number extends O['length'] ? _Pick<O, number> : _Omit<O, keyof any[]> : O;
}
declare module "List/Omit" {
    import { _Omit as _OOmit } from "Object/Omit";
    import { _ListOf } from "Object/ListOf";
    import { Key } from "Any/Key";
    import { List } from "List/List";
    import { ObjectOf } from "List/ObjectOf";
    import { NumberOf } from "Any/_Internal";
    /**
    @hidden
    */
    export type _Omit<L extends List, K extends Key> = _ListOf<_OOmit<ObjectOf<L>, NumberOf<K>>>;
    /**
    Remove out of **`L`** the entries of key **`K`**
    @param L to remove from
    @param K to chose entries
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Omit<L extends List, K extends Key> = L extends unknown ? _Omit<L, K> : never;
}
declare module "Any/Omit" {
    import { _Omit as _OOmit } from "Object/Omit";
    import { _Omit as _LOmit } from "List/Omit";
    import { Key } from "Any/Key";
    import { List } from "List/List";
    import { Union } from "Union/Union";
    /**
     * Remove out from each member of union **`U`** the fields of key **`K`**
     * @param U to remove from
     * @param K to chose fields
     * @returns [[Union]]
     * @example
     * ```ts
     * import {U} from 'ts-toolbelt'
     *
     * type O = {type: 'foo'; other: number} | {type: 'bar'; other: string} | [0, 1]
     * type test0 = U.Omit<O, 'other' | '0'> // {type: 'foo'} | {type: 'bar'} | [1]
     * ```
     */
    export type Omit<U extends Union, K extends Key> = U extends object ? U extends List ? _LOmit<U, K> : _OOmit<U, K> : U;
}
declare module "List/Pick" {
    import { _Pick as _OPick } from "Object/Pick";
    import { _ListOf } from "Object/ListOf";
    import { Key } from "Any/Key";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    import { NumberOf } from "Any/_Internal";
    /**
    @hidden
    */
    export type _Pick<L extends List, K extends Key> = _ListOf<_OPick<ObjectOf<L>, NumberOf<K>>>;
    /**
    Extract out of **`L`** the entries of key **`K`**
    @param L to extract from
    @param K to chose entries
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Pick<L extends List, K extends Key> = L extends unknown ? _Pick<L, K> : never;
}
declare module "Any/Pick" {
    import { _Pick as _OPick } from "Object/Pick";
    import { _Pick as _LPick } from "List/Pick";
    import { Key } from "Any/Key";
    import { List } from "List/List";
    import { Union } from "Union/Union";
    /**
     * Extract out from each member of union **`U`** the fields of key **`K`**
     * @param U to remove from
     * @param K to chose fields
     * @returns [[Union]]
     * @example
     * ```ts
     * import {U} from 'ts-toolbelt'
     *
     * type O = {type: 'foo'; other: number} | {type: 'bar'; other: string} | [0, 1]
     * type test0 = U.Pick<O, 'type' | '1'> // {type: 'foo'} | {type: 'bar'} | [1]
     * ```
     */
    export type Pick<U extends Union, K extends Key> = U extends object ? U extends List ? _LPick<U, K> : _OPick<U, K> : U;
}
declare module "Any/_api" {
    /** @ignore */ /** */
    export { Cast } from "Any/Cast";
    export { Clean } from "Any/Clean";
    export { Compute } from "Any/Compute";
    export { Contains } from "Any/Contains";
    export { Equals } from "Any/Equals";
    export { Extends } from "Any/Extends";
    export { Key } from "Any/Key";
    export { Is } from "Any/Is";
    export { IsLiteral } from "Any/IsLiteral";
    export { Kind } from "Any/Kind";
    export { Promisable } from "Any/Promisable";
    export { Promise } from "Any/Promise";
    export { PromiseOf } from "Any/PromiseOf";
    export { Try } from "Any/Try";
    export { Type } from "Any/Type";
    export { x } from "Any/x";
    export { Omit } from "Any/Omit";
    export { Pick } from "Any/Pick";
    export { Contains as Implements } from "Any/Contains";
}
declare module "Boolean/BooleanOf" {
    /**
    Transform a **`boolean`** into a [[Boolean]]
    @param B to transform
    @returns [[Boolean]]
    @example
    ```ts
    type test0 = B.BooleanOf<true>  // 1
    type test1 = B.BooleanOf<false> // 0
    ```
    */
    export type BooleanOf<B extends boolean> = B extends true ? 1 : 0;
}
declare module "Boolean/_Internal" {
    /**
    Describes compatible type formats
    * `b`: **`boolean`**
    * `n`: **`number`**
    * `s`: **`string`**
    */
    export type Formats = 'b' | 'n' | 's';
}
declare module "Boolean/Format" {
    import { Boolean } from "Boolean/Boolean";
    import { Formats } from "Boolean/_Internal";
    /**
    Change the format of a [[Boolean]]
    @param B to transform
    @returns **`string | number | boolean`**
    @example
    ```ts
    import {B} from 'ts-toolbelt'
    
    type test0 = B.Format<B.True, 's'> // 'true'
    type test1 = B.Format<B.True, 'b'> //  true
    ```
    */
    export type Format<B extends Boolean, fmt extends Formats> = {
        'b': [false, true][B];
        'n': B;
        's': ['false', 'true'][B];
    }[fmt];
}
declare module "Boolean/Xor" {
    import { Boolean } from "Boolean/Boolean";
    /**
    Logical **`^`** operator (behaves like the JS one)
    @param B1 Left-hand side
    @param B2 Right-hand side
    @returns [[Boolean]]
    @example
    ```ts
    import {B} from 'ts-toolbelt'
    
    type test0 = B.Xor<B.True, B.True>    // False
    type test1 = B.Xor<B.False, B.True>   // True
    type test2 = B.Xor<B.Boolean, B.True> // Boolean
    ```
    */
    export type Xor<B1 extends Boolean, B2 extends Boolean> = {
        0: {
            0: 0;
            1: 1;
        };
        1: {
            0: 1;
            1: 0;
        };
    }[B1][B2];
}
declare module "Boolean/_api" {
    /** @ignore */ /** */
    export { And } from "Boolean/And";
    export { True, False, Boolean } from "Boolean/Boolean";
    export { BooleanOf } from "Boolean/BooleanOf";
    export { Format } from "Boolean/Format";
    export { Not } from "Boolean/Not";
    export { Or } from "Boolean/Or";
    export { Xor } from "Boolean/Xor";
}
declare module "Class/Class" {
    import { List } from "List/List";
    /**
    Alias to create/describe a [[Class]]
    @param P its constructor parameters
    @param R the object it constructs
    */
    export type Class<P extends List = any[], R extends object = object> = {
        new (...args: P): R;
    };
}
declare module "Class/InstanceOf" {
    import { Class } from "Class/Class";
    /**
    Get the instance type of a **`class`** from a class object
    @param C **typeof** **`class`**
    @returns **`class`**
    @example
    ```ts
    import {C} from 'ts-toolbelt'
    
    /// `create` takes an instance constructor and creates an instance of it
    declare function create<C extends (new (...args: any[]) => any)>(c: C): C.InstanceOf<C>
    
    class A {}
    class B {}
    
    let a = create(A) // A
    let b = create(B) // B
    ```
    */
    export type InstanceOf<C extends Class> = C extends Class<any[], infer R> ? R : any;
}
declare module "Class/Parameters" {
    import { Class } from "Class/Class";
    /**
    Get the parameters of a class constructor
    @param C **typeof** **`class`**
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Parameters<C> = C extends Class<infer P, any> ? P : never;
}
declare module "Class/_api" {
    /** @ignore */ /** */
    export { Class } from "Class/Class";
    export { InstanceOf } from "Class/InstanceOf";
    export { Parameters } from "Class/Parameters";
    export { PromiseOf } from "Any/PromiseOf";
}
declare module "Object/UnionOf" {
    import { At } from "Object/At";
    /**
     * @hidden
     */
    export type _UnionOf<O extends object> = At<O, keyof O>;
    /**
    Transform an [[Object]] into an [[Union]]
    @param O to transform
    @returns **`any`**
    @example
    ```ts
    ```
    */
    export type UnionOf<O extends object> = O extends unknown ? _UnionOf<O> : never;
}
declare module "Iteration/Prev" {
    import { Map } from "Iteration/Map";
    import { Iteration } from "Iteration/Iteration";
    import { NumberMap } from "Iteration/Maps/Number";
    /**
    Move **`I`**'s position backwards
    @param I to move
    @param IMap to operate with another set of numbers
    @returns [[Iteration]]
    @example
    ```ts
    import {I} from 'ts-toolbelt'
    
    type i = I.IterationOf<'20'>
    
    type test0 = I.Pos<i>         // 20
    type test1 = I.Pos<I.Prev<i>> // 19
    ```
    */
    export type Prev<I extends Iteration, IMap extends Map = NumberMap> = IMap[1][I[0]];
}
declare module "Community/IncludesDeep" {
    import { Match } from "Any/_Internal";
    import { Number } from "Number/Number";
    import { UnionOf } from "Object/UnionOf";
    import { Next } from "Iteration/Next";
    import { Key } from "Iteration/Key";
    import { Prev } from "Iteration/Prev";
    import { Iteration } from "Iteration/Iteration";
    import { IterationOf } from "Iteration/IterationOf";
    import { Is } from "Any/Is";
    import { Boolean } from "Boolean/Boolean";
    import { Cast } from "Any/Cast";
    /**
     * @hidden
     */
    type _IncludesDeep<O, M extends any, match extends Match, limit extends Number, I extends Iteration = IterationOf<'0'>> = {
        0: _IncludesDeep<O extends object ? UnionOf<O> : O, M, match, limit, Next<I>>;
        1: 1;
        2: 0;
    }[Key<Prev<I>> extends limit ? 2 : Is<O, M, match>];
    /**
     * Check whether **`O`**, or its sub-objects have fields that match **`M`**
     * where the maximum allowed depth is set with **`limit`**.
     *
     * @param O to be inspected
     * @param M to check field type
     * @param match (?=`'default'`) to change precision
     * @param limit (?=`'10'`) to change the check depth
     * @returns [[Boolean]]
     * @example
     * ```ts
     * ```
     * @author millsp, ctrlplusb
     */
    export type IncludesDeep<O extends object, M extends any, match extends Match = 'default', limit extends Number = '10'> = _IncludesDeep<O, M, match, limit> extends infer X ? Cast<X, Boolean> : never;
}
declare module "Community/_api" {
    /** @ignore */ /** */
    export { IncludesDeep } from "Community/IncludesDeep";
}
declare module "Function/_Internal" {
    /**
    Describes function modes
    * `sync` : Normal function
    * `async`: Promised result
    */
    export type Mode = 'sync' | 'async';
    /**
    Describes function parameter input
    * `multi`: ( a, b, c ... n ) => X
    * `list` : ([a, b, c ... n]) => X
    */
    export type Input = 'multi' | 'list';
}
declare module "Function/Function" {
    import { List } from "List/List";
    /**
    Alias to create a [[Function]]
    @param P parameters
    @param R return type
    @returns [[Function]]
    @example
    ```ts
    import {F} from 'ts-toolbelt'
    
    type test0 = F.Function<[string, number], boolean>
    /// (args_0: string, args_1: number) => boolean
    ```
    */
    export interface Function<P extends List = any, R extends any = any> {
        (...args: P): R;
    }
}
declare module "Function/Compose/Multi/Sync" {
    /** @ignore */ /** */
    import { Function } from "Function/Function";
    /**
    @hidden
     */
    export type ComposeMultiSync = {
        <R0, P extends any[]>(...fns: [
            Function<P, R0>
        ]): Function<P, R0>;
        <R0, R1, P extends any[]>(...fns: [
            Function<[R0], R1>,
            Function<P, R0>
        ]): Function<P, R1>;
        <R0, R1, R2, P extends any[]>(...fns: [
            Function<[R1], R2>,
            Function<[R0], R1>,
            Function<P, R0>
        ]): Function<P, R2>;
        <R0, R1, R2, R3, P extends any[]>(...fns: [
            Function<[R2], R3>,
            Function<[R1], R2>,
            Function<[R0], R1>,
            Function<P, R0>
        ]): Function<P, R3>;
        <R0, R1, R2, R3, R4, P extends any[]>(...fns: [
            Function<[R3], R4>,
            Function<[R2], R3>,
            Function<[R1], R2>,
            Function<[R0], R1>,
            Function<P, R0>
        ]): Function<P, R4>;
        <R0, R1, R2, R3, R4, R5, P extends any[]>(...fns: [
            Function<[R4], R5>,
            Function<[R3], R4>,
            Function<[R2], R3>,
            Function<[R1], R2>,
            Function<[R0], R1>,
            Function<P, R0>
        ]): Function<P, R5>;
        <R0, R1, R2, R3, R4, R5, R6, P extends any[]>(...fns: [
            Function<[R5], R6>,
            Function<[R4], R5>,
            Function<[R3], R4>,
            Function<[R2], R3>,
            Function<[R1], R2>,
            Function<[R0], R1>,
            Function<P, R0>
        ]): Function<P, R6>;
        <R0, R1, R2, R3, R4, R5, R6, R7, P extends any[]>(...fns: [
            Function<[R6], R7>,
            Function<[R5], R6>,
            Function<[R4], R5>,
            Function<[R3], R4>,
            Function<[R2], R3>,
            Function<[R1], R2>,
            Function<[R0], R1>,
            Function<P, R0>
        ]): Function<P, R7>;
        <R0, R1, R2, R3, R4, R5, R6, R7, R8, P extends any[]>(...fns: [
            Function<[R7], R8>,
            Function<[R6], R7>,
            Function<[R5], R6>,
            Function<[R4], R5>,
            Function<[R3], R4>,
            Function<[R2], R3>,
            Function<[R1], R2>,
            Function<[R0], R1>,
            Function<P, R0>
        ]): Function<P, R8>;
        <R0, R1, R2, R3, R4, R5, R6, R7, R8, R9, P extends any[]>(...fns: [
            Function<[R8], R9>,
            Function<[R7], R8>,
            Function<[R6], R7>,
            Function<[R5], R6>,
            Function<[R4], R5>,
            Function<[R3], R4>,
            Function<[R2], R3>,
            Function<[R1], R2>,
            Function<[R0], R1>,
            Function<P, R0>
        ]): Function<P, R9>;
    };
}
declare module "Function/Compose/Multi/Async" {
    /** @ignore */ /** */
    import { Function } from "Function/Function";
    import { PromiseOf } from "Any/PromiseOf";
    /**
    @hidden
     */
    export type ComposeMultiAsync = {
        <R0, P extends any[]>(...fns: [
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R0>>>;
        <R0, R1, P extends any[]>(...fns: [
            Function<[PromiseOf<R0>], R1>,
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R1>>>;
        <R0, R1, R2, P extends any[]>(...fns: [
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R0>], R1>,
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R2>>>;
        <R0, R1, R2, R3, P extends any[]>(...fns: [
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R0>], R1>,
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R3>>>;
        <R0, R1, R2, R3, R4, P extends any[]>(...fns: [
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R0>], R1>,
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R4>>>;
        <R0, R1, R2, R3, R4, R5, P extends any[]>(...fns: [
            Function<[PromiseOf<R4>], R5>,
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R0>], R1>,
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R5>>>;
        <R0, R1, R2, R3, R4, R5, R6, P extends any[]>(...fns: [
            Function<[PromiseOf<R5>], R6>,
            Function<[PromiseOf<R4>], R5>,
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R0>], R1>,
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R6>>>;
        <R0, R1, R2, R3, R4, R5, R6, R7, P extends any[]>(...fns: [
            Function<[PromiseOf<R6>], R7>,
            Function<[PromiseOf<R5>], R6>,
            Function<[PromiseOf<R4>], R5>,
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R0>], R1>,
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R7>>>;
        <R0, R1, R2, R3, R4, R5, R6, R7, R8, P extends any[]>(...fns: [
            Function<[PromiseOf<R7>], R8>,
            Function<[PromiseOf<R6>], R7>,
            Function<[PromiseOf<R5>], R6>,
            Function<[PromiseOf<R4>], R5>,
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R0>], R1>,
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R8>>>;
        <R0, R1, R2, R3, R4, R5, R6, R7, R8, R9, P extends any[]>(...fns: [
            Function<[PromiseOf<R8>], R9>,
            Function<[PromiseOf<R7>], R8>,
            Function<[PromiseOf<R6>], R7>,
            Function<[PromiseOf<R5>], R6>,
            Function<[PromiseOf<R4>], R5>,
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R0>], R1>,
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R9>>>;
    };
}
declare module "Function/Compose/List/Sync" {
    /** @ignore */ /** */
    import { Function } from "Function/Function";
    /**
    @hidden
     */
    export type ComposeListSync = {
        <R0, P extends any[]>(fns: [
            Function<P, R0>
        ]): Function<P, R0>;
        <R0, R1, P extends any[]>(fns: [
            Function<[R0], R1>,
            Function<P, R0>
        ]): Function<P, R1>;
        <R0, R1, R2, P extends any[]>(fns: [
            Function<[R1], R2>,
            Function<[R0], R1>,
            Function<P, R0>
        ]): Function<P, R2>;
        <R0, R1, R2, R3, P extends any[]>(fns: [
            Function<[R2], R3>,
            Function<[R1], R2>,
            Function<[R0], R1>,
            Function<P, R0>
        ]): Function<P, R3>;
        <R0, R1, R2, R3, R4, P extends any[]>(fns: [
            Function<[R3], R4>,
            Function<[R2], R3>,
            Function<[R1], R2>,
            Function<[R0], R1>,
            Function<P, R0>
        ]): Function<P, R4>;
        <R0, R1, R2, R3, R4, R5, P extends any[]>(fns: [
            Function<[R4], R5>,
            Function<[R3], R4>,
            Function<[R2], R3>,
            Function<[R1], R2>,
            Function<[R0], R1>,
            Function<P, R0>
        ]): Function<P, R5>;
        <R0, R1, R2, R3, R4, R5, R6, P extends any[]>(fns: [
            Function<[R5], R6>,
            Function<[R4], R5>,
            Function<[R3], R4>,
            Function<[R2], R3>,
            Function<[R1], R2>,
            Function<[R0], R1>,
            Function<P, R0>
        ]): Function<P, R6>;
        <R0, R1, R2, R3, R4, R5, R6, R7, P extends any[]>(fns: [
            Function<[R6], R7>,
            Function<[R5], R6>,
            Function<[R4], R5>,
            Function<[R3], R4>,
            Function<[R2], R3>,
            Function<[R1], R2>,
            Function<[R0], R1>,
            Function<P, R0>
        ]): Function<P, R7>;
        <R0, R1, R2, R3, R4, R5, R6, R7, R8, P extends any[]>(fns: [
            Function<[R7], R8>,
            Function<[R6], R7>,
            Function<[R5], R6>,
            Function<[R4], R5>,
            Function<[R3], R4>,
            Function<[R2], R3>,
            Function<[R1], R2>,
            Function<[R0], R1>,
            Function<P, R0>
        ]): Function<P, R8>;
        <R0, R1, R2, R3, R4, R5, R6, R7, R8, R9, P extends any[]>(fns: [
            Function<[R8], R9>,
            Function<[R7], R8>,
            Function<[R6], R7>,
            Function<[R5], R6>,
            Function<[R4], R5>,
            Function<[R3], R4>,
            Function<[R2], R3>,
            Function<[R1], R2>,
            Function<[R0], R1>,
            Function<P, R0>
        ]): Function<P, R9>;
    };
}
declare module "Function/Compose/List/Async" {
    /** @ignore */ /** */
    import { Function } from "Function/Function";
    import { PromiseOf } from "Any/PromiseOf";
    /**
    @hidden
     */
    export type ComposeListAsync = {
        <R0, P extends any[]>(fns: [
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R0>>>;
        <R0, R1, P extends any[]>(fns: [
            Function<[PromiseOf<R0>], R1>,
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R1>>>;
        <R0, R1, R2, P extends any[]>(fns: [
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R0>], R1>,
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R2>>>;
        <R0, R1, R2, R3, P extends any[]>(fns: [
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R0>], R1>,
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R3>>>;
        <R0, R1, R2, R3, R4, P extends any[]>(fns: [
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R0>], R1>,
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R4>>>;
        <R0, R1, R2, R3, R4, R5, P extends any[]>(fns: [
            Function<[PromiseOf<R4>], R5>,
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R0>], R1>,
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R5>>>;
        <R0, R1, R2, R3, R4, R5, R6, P extends any[]>(fns: [
            Function<[PromiseOf<R5>], R6>,
            Function<[PromiseOf<R4>], R5>,
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R0>], R1>,
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R6>>>;
        <R0, R1, R2, R3, R4, R5, R6, R7, P extends any[]>(fns: [
            Function<[PromiseOf<R6>], R7>,
            Function<[PromiseOf<R5>], R6>,
            Function<[PromiseOf<R4>], R5>,
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R0>], R1>,
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R7>>>;
        <R0, R1, R2, R3, R4, R5, R6, R7, R8, P extends any[]>(fns: [
            Function<[PromiseOf<R7>], R8>,
            Function<[PromiseOf<R6>], R7>,
            Function<[PromiseOf<R5>], R6>,
            Function<[PromiseOf<R4>], R5>,
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R0>], R1>,
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R8>>>;
        <R0, R1, R2, R3, R4, R5, R6, R7, R8, R9, P extends any[]>(fns: [
            Function<[PromiseOf<R8>], R9>,
            Function<[PromiseOf<R7>], R8>,
            Function<[PromiseOf<R6>], R7>,
            Function<[PromiseOf<R5>], R6>,
            Function<[PromiseOf<R4>], R5>,
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R0>], R1>,
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R9>>>;
    };
}
declare module "List/Tail" {
    import { List } from "List/List";
    /**
    Remove the first item out of a [[List]]
    @param L
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Tail<L extends List> = ((...t: L) => any) extends ((head: any, ...tail: infer LTail) => any) ? LTail : never;
}
declare module "List/Last" {
    import { Tail } from "List/Tail";
    import { Length } from "List/Length";
    import { List } from "List/List";
    /**
    Get the last entry of **`L`**
    @param L to extract from
    @returns **`any`**
    @example
    ```ts
    ```
    */
    export type Last<L extends List> = L[Length<Tail<L>>];
}
declare module "String/_Internal" {
    /**
    Describes compatible type formats
    * `b`: **`boolean`**
    * `s`: **`string`**
    * `n`: **`number`**
    */
    export type Formats = 'b' | 'n' | 's';
}
declare module "String/Format" {
    import { Formats } from "String/_Internal";
    import { Pos } from "Iteration/Pos";
    import { IterationOf } from "Iteration/IterationOf";
    import { Extends } from "Any/Extends";
    /**
    Change the format of a **`string`**
    @param S to transform
    @returns **`string | number | boolean`**
    @example
    ```ts
    import {S} from 'ts-toolbelt'
    
    type test0 = S.Format<'30', 'b'> // True
    type test1 = S.Format<'30', 'n'> // 30
    ```
    */
    export type Format<S extends string, fmt extends Formats> = {
        'b': {
            1: Boolean;
            0: S extends 'false' ? 0 : 1;
        }[Extends<string, S>];
        'n': Pos<IterationOf<S>>;
        's': S;
    }[fmt];
}
declare module "List/Head" {
    import { Length } from "List/Length";
    import { List } from "List/List";
    /**
    Get the first entry of **`L`**
    @param L to extract from
    @returns **`any`**
    @example
    ```ts
    ```
    */
    export type Head<L extends List> = Length<L> extends 0 ? never : L[0];
}
declare module "Function/Return" {
    import { Function } from "Function/Function";
    import { List } from "List/List";
    /**
    Extract the return type of a [[Function]]
    @param F to extract from
    @returns **`any`**
    @example
    ```ts
    import {F} from 'ts-toolbelt'
    
    const fn = () => true
    
    type test0 = F.ReturnOf<typeof fn>  // boolean
    
    type test1 = F.ReturnOf<() => true> // true
    ```
    */
    export type Return<F extends Function> = F extends ((...args: List) => infer R) ? R : never;
}
declare module "Function/Parameters" {
    import { Function } from "Function/Function";
    /**
    Extract parameters from a [[Function]]
    @param F to extract from
    @returns [[List]]
    @example
    ```ts
    import {F} from 'ts-toolbelt'
    
    const fn = (name: string, age: number) => {}
    
    type test0 = F.ParamsOf<typeof fn>                         // [string, number]
    
    type test1 = F.ParamsOf<(name: string, age: number) => {}> // [string, number]
    ```
    */
    export type Parameters<F extends Function> = F extends ((...args: infer L) => any) ? L : never;
}
declare module "Union/IntersectOf" {
    import { Union } from "Union/Union";
    /**
    Transform a [[Union]] to an **intersection**
    @param U to transform
    @returns **intersection**
    @example
    ```ts
    ```
    */
    export type IntersectOf<U extends Union> = (U extends unknown ? (k: U) => void : never) extends ((k: infer I) => void) ? I : never;
}
declare module "Function/Compose" {
    import { Mode, Input } from "Function/_Internal";
    import { ComposeMultiSync } from "Function/Compose/Multi/Sync";
    import { ComposeMultiAsync } from "Function/Compose/Multi/Async";
    import { ComposeListSync } from "Function/Compose/List/Sync";
    import { ComposeListAsync } from "Function/Compose/List/Async";
    import { Function } from "Function/Function";
    import { Pos } from "Iteration/Pos";
    import { IterationOf } from "Iteration/IterationOf";
    import { Last } from "List/Last";
    import { Format } from "String/Format";
    import { Length } from "List/Length";
    import { Tail } from "List/Tail";
    import { Next } from "Iteration/Next";
    import { Head } from "List/Head";
    import { Return } from "Function/Return";
    import { Parameters } from "Function/Parameters";
    import { PromiseOf } from "Any/PromiseOf";
    import { Or } from "Boolean/Or";
    import { Extends } from "Any/Extends";
    import { List } from "List/List";
    import { IntersectOf } from "Union/IntersectOf";
    /**
    @hidden
    */
    type ComposeFnSync<Fns extends List<Function>, K extends keyof Fns> = Length<Tail<Fns>> extends Format<K & string, 'n'> ? Fns[K] : Function<[
        Return<Fns[Pos<Next<IterationOf<K & string>>>]> extends infer X ? {
            1: any;
            0: X;
        }[Or<Extends<unknown, X>, Extends<unknown[], X>>] : never
    ], Return<Fns[Pos<IterationOf<K & string>>]>>;
    /**
    @hidden
    */
    type ComposeFnAsync<Fns extends List<Function>, K extends keyof Fns> = Length<Tail<Fns>> extends Format<K & string, 'n'> ? PromiseOf<Fns[K]> : Function<[
        PromiseOf<Return<Fns[Pos<Next<IterationOf<K & string>>>]>> extends infer X ? {
            1: any;
            0: X;
        }[Or<Extends<unknown, X>, Extends<unknown[], X>>] : never
    ], Return<Fns[Pos<IterationOf<K & string>>]>>;
    /**
    Compute what the input of [[Compose]] should be
    @param Fns to compose
    @param mode (?=`'sync'`) sync/async
    @example
    ```ts
    ```
    */
    export type Composer<Fns extends List<Function>, mode extends Mode = 'sync'> = {
        'sync': {
            [K in keyof Fns]: ComposeFnSync<Fns, K>;
        };
        'async': {
            [K in keyof Fns]: ComposeFnAsync<Fns, K>;
        };
    }[mode];
    /**
    Compose [[Function]]s together
    @param Fns to compose
    @returns [[Function]]
    @example
    ```ts
    import {F} from 'ts-toolbelt'
    
    /// If you are looking for creating types for `compose`
    /// `Composer` will check for input & `Composed` the output
    declare function compose<Fns extends F.Function[]>(...args: F.Composer<Fns>): F.Composed<Fns>
    
    const a = (a1: number) => `${a1}`
    const c = (c1: string[]) => [c1]
    const b = (b1: string) => [b1]
    
    compose(c, b, a)(42)
    
    /// And if you are looking for an async `compose` type
    declare function compose<Fns extends F.Function[]>(...args: F.Composer<Fns, 'async'>): F.Composed<Fns, 'async'>
    
    const a = async (a1: number) => `${a1}`
    const b = async (b1: string) => [b1]
    const c = async (c1: string[]) => [c1]
    
    await compose(c, b, a)(42)
    */
    export type Composed<Fns extends List<Function>, mode extends Mode = 'sync'> = {
        'sync': (...args: Parameters<Last<Fns>>) => Return<Head<Fns>>;
        'async': (...args: Parameters<Last<Fns>>) => Promise<PromiseOf<Return<Head<Fns>>>>;
    }[mode];
    /**
    Compose [[Function]]s together
    @param mode  (?=`'sync'`)    sync/async (this depends on your implementation)
    @param input (?=`'multi'`)   whether you want it to take a list or parameters
    @example
    ```ts
    import {F} from 'ts-toolbelt'
    
    /// If you are looking for creating types for `compose`
    /// `Composer` will check for input & `Compose` the output
    declare const compose: F.Compose
    
    const a = (a1: number) => `${a1}`
    const c = (c1: string[]) => [c1]
    const b = (b1: string) => [b1]
    
    compose(c, b, a)(42)
    
    /// And if you are looking for an async `compose` type
    declare const compose: F.Compose<'async'>
    
    const a = async (a1: number) => `${a1}`
    const b = async (b1: string) => [b1]
    const c = async (c1: string[]) => [c1]
    
    await compose(c, b, a)(42)
    */
    export type Compose<mode extends Mode = 'sync', input extends Input = 'multi'> = IntersectOf<{
        'sync': {
            'multi': ComposeMultiSync;
            'list': ComposeListSync;
        };
        'async': {
            'multi': ComposeMultiAsync;
            'list': ComposeListAsync;
        };
    }[mode][input]>;
}
declare module "Union/NonNullable" {
    import { Exclude } from "Union/Exclude";
    import { Union } from "Union/Union";
    /**
    Remove **`undefined`** & **`null`** out of **`U`**
    @param U to make non-nullable
    @returns [[Union]]
    @example
    ```ts
    ```
    */
    export type NonNullable<U extends Union> = Exclude<U, undefined | null>;
}
declare module "Object/Patch" {
    import { AtBasic } from "Object/At";
    import { Key } from "Any/Key";
    import { _ListOf } from "Object/ListOf";
    import { List } from "List/List";
    import { Depth, MergeStyle } from "Object/_Internal";
    import { BuiltInObject } from "Misc/BuiltInObject";
    import { _Omit } from "Object/Omit";
    import { ObjectOf } from "List/ObjectOf";
    /**
    @hidden
    */
    type LibStyle<Merged, O, O1, style extends MergeStyle> = {
        0: [O] extends [List] ? [O1] extends [List] ? _ListOf<Merged & {}> : O : Merged;
        1: Merged;
        2: [O] extends [List] ? [O1] extends [List] ? Merged[keyof Merged][] : O : Merged;
    }[style];
    /**
    @hidden
    */
    type PatchProp<OK, O1K, K extends Key, OOK extends Key> = K extends OOK ? OK : O1K;
    /**
    @hidden
    */
    type __PatchFlat<O extends object, O1 extends object, OOK extends Key = keyof O> = {
        [K in keyof (O & _Omit<O1, OOK>)]: PatchProp<AtBasic<O, K>, AtBasic<O1, K>, K, OOK>;
    } & {};
    /**
    @hidden
    */
    export type _PatchFlat<O extends object, O1 extends object, style extends MergeStyle> = LibStyle<__PatchFlat<ObjectOf<O>, ObjectOf<O1>>, O, O1, style>;
    /**
    @hidden
    */
    export type PatchFlat<O extends object, O1 extends object, style extends MergeStyle = 2, noMerge = BuiltInObject> = O extends noMerge ? O : O1 extends noMerge ? O : _PatchFlat<O, O1, style>;
    /**
    @hidden
    */
    type __PatchDeep<O extends object, O1 extends object, style extends MergeStyle, noMerge, OOK extends Key = keyof O> = {
        [K in keyof (O & _Omit<O1, OOK>)]: _PatchDeep<AtBasic<O, K>, AtBasic<O1, K>, K, OOK, style, noMerge>;
    };
    /**
    @hidden
    */
    type ChoosePatchDeep<OK, O1K, K extends Key, OOK extends Key, style extends MergeStyle, noMerge> = OK extends BuiltInObject ? PatchProp<OK, O1K, K, OOK> : O1K extends BuiltInObject ? PatchProp<OK, O1K, K, OOK> : OK extends object ? O1K extends object ? __PatchDeep<ObjectOf<OK>, ObjectOf<O1K>, style, noMerge> : PatchProp<OK, O1K, K, OOK> : PatchProp<OK, O1K, K, OOK>;
    /**
    @hidden
    */
    export type _PatchDeep<O, O1, K extends Key, OOK extends Key, style extends MergeStyle, noMerge> = [
        O
    ] extends [never] ? PatchProp<O, O1, K, OOK> : [O1] extends [never] ? PatchProp<O, O1, K, OOK> : LibStyle<ChoosePatchDeep<O, O1, K, OOK, style, noMerge>, O, O1, style>;
    /**
    @hidden
    */
    export type PatchDeep<O, O1, style extends MergeStyle, noMerge> = O extends unknown ? O1 extends unknown ? _PatchDeep<O, O1, 'x', 'y', style, noMerge> : never : never;
    /**
    Complete the fields of **`O`** with the ones of **`O1`**. This is a version of
    [[Merge]] that does NOT handle optional fields, it only completes fields of `O`
    with the ones of `O1`.
    @param O to complete
    @param O1 to copy from
    @param depth (?=`'flat'`) to do it deeply
    @param style (?=`1`) 0 = lodash, 1 = ramda
    @param noMerge (?=`BuiltinObject`) types not to merge
    @returns [[Object]]
    @example
    ```ts
    import {O} from 'ts-toolbelt'
    
    type O = {
        name?: string
        age? : number
        zip? : string
        pay  : {
            cvv?: number
        }
    }
    
    type O1 = {
        age : number
        zip?: number
        city: string
        pay : {
            cvv : number
            ccn?: string
        }
    }
    
    type test = O.Patch<O, O1, 'deep'>
    // {
    //     name?: string;
    //     age?: number;
    //     zip?: string | number;
    //     pay: {
    //         cvv?: number;
    //         ccn?: string;
    //     };
    //     city: string;
    // }
    ```
    */
    export type Patch<O extends object, O1 extends object, depth extends Depth = 'flat', style extends MergeStyle = 2, noMerge = BuiltInObject> = {
        'flat': PatchFlat<O, O1, style, noMerge>;
        'deep': PatchDeep<O, O1, style, noMerge>;
    }[depth];
}
declare module "Object/NonNullable" {
    import { NonNullable as UNonNullable } from "Union/NonNullable";
    import { Depth } from "Object/_Internal";
    import { _Pick } from "Object/Pick";
    import { Key } from "Any/Key";
    import { _PatchFlat } from "Object/Patch";
    import { BuiltInObject } from "Misc/BuiltInObject";
    /**
    @hidden
    */
    export type NonNullableFlat<O> = {
        [K in keyof O]: UNonNullable<O[K]>;
    } & {};
    /**
    @hidden
    */
    export type NonNullableDeep<O> = {
        [K in keyof O]: O[K] extends BuiltInObject ? O[K] : NonNullableDeep<UNonNullable<O[K]>>;
    };
    /**
    @hidden
    */
    export type NonNullablePart<O extends object, depth extends Depth> = {
        'flat': NonNullableFlat<O>;
        'deep': NonNullableDeep<O>;
    }[depth];
    /**
     * @hidden
     */
    export type _NonNullable<O extends object, K extends Key, depth extends Depth> = _PatchFlat<NonNullablePart<_Pick<O, K>, depth>, O, 2>;
    /**
    Make some fields of **`O`** not nullable (deeply or not)
    (Optional fields will be left untouched & **`undefined`**)
    @param O to make non nullable
    @param K (?=`Key`) to choose fields
    @param depth (?=`'flat'`) to do it deeply
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type NonNullable<O extends object, K extends Key = Key, depth extends Depth = 'flat'> = O extends unknown ? _NonNullable<O, K, depth> : never;
}
declare module "Function/Curry" {
    import { Pos } from "Iteration/Pos";
    import { _Append } from "List/Append";
    import { _Concat } from "List/Concat";
    import { Length } from "List/Length";
    import { Next } from "Iteration/Next";
    import { Cast } from "Any/Cast";
    import { Parameters } from "Function/Parameters";
    import { Return } from "Function/Return";
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { NonNullableFlat } from "Object/NonNullable";
    import { x } from "Any/x";
    import { List } from "List/List";
    import { Function } from "Function/Function";
    import { Extends } from "Any/Extends";
    import { Tail } from "List/Tail";
    /**
    @hidden
    */
    type GapOf<L1 extends List, L2 extends List, LN extends List, I extends Iteration> = L1[Pos<I>] extends x ? _Append<LN, L2[Pos<I>]> : LN;
    /**
    @hidden
    */
    type _GapsOf<L1 extends List, L2 extends List, LN extends List = [], L2D extends List = L2, I extends Iteration = IterationOf<'0'>> = {
        0: _GapsOf<L1, L2, GapOf<L1, L2, LN, I>, Tail<L2D>, Next<I>>;
        1: _Concat<LN, L2D>;
    }[Extends<Pos<I>, Length<L1>>];
    /**
    @hidden
    */
    type GapsOf<L1 extends List, L2 extends List> = _GapsOf<L1, L2> extends infer X ? Cast<X, List> : never;
    /**
    @hidden
    */
    type Gaps<L extends List> = Cast<NonNullableFlat<{
        [K in keyof L]?: L[K] | x;
    }>, List>;
    /**
    Curry a [[Function]]
    @param F to curry
    @returns [[Function]]
    @example
    ```ts
    import {F} from 'ts-toolbelt'
    
    /// If you are looking for creating types for `curry`
    /// It handles placeholders and variable arguments
    declare function curry<Fn extends F.Function>(fn: Fn): F.Curry<Fn>
    ```
    */
    export type Curry<F extends Function> = <L extends List, G extends List = GapsOf<L, Parameters<F>>, R extends any = Return<F>>(...args: Cast<L, Gaps<Parameters<F>>>) => Length<G> extends 0 ? R : Length<G> extends 1 ? Curry<(...args: G) => R> & ((...args: G) => R) : Curry<(...args: G) => R>;
}
declare module "Function/Length" {
    import { Function } from "Function/Function";
    import { Parameters } from "Function/Parameters";
    import { Formats } from "Iteration/_Internal";
    import { Length as LLength } from "List/Length";
    /**
    Extract arguments' length from a [[Function]]
    @param F to extract from
    @param fmt (?=`'n'`) output
    @returns [[String]] or **`number`**
    @example
    ```ts
    import {F} from 'ts-toolbelt'
    
    const fn = (a1: any, a2: any) => {}
    
    type test0 = F.LengthOf<typeof fn>               // 2
    
    type test1 = F.LengthOf<(a1?: any) => any>       // 0 | 1
    
    type test2 = F.LengthOf<(...a: any[]) => any>    // number
    ```
    */
    export type Length<Fn extends Function, fmt extends Formats = 'n'> = LLength<Parameters<Fn>, fmt>;
}
declare module "Function/NoInfer" {
    /**
    Explain to TS which function parameter has priority for generic inference
    @param A to de-prioritize
    @returns **`A`**
    @example
    ```ts
    import {F} from 'ts-toolbelt'
    
    const fn0 = <A extends any>(a0: A, a1: F.NoInfer<A>): A => {
        return {} as unknown as A // just for the example
    }
    
    const fn1 = <A extends any>(a0: F.NoInfer<A>, a1: A): A => {
        return {} as unknown as A // just for the example
    }
    
    const fn2 = <A extends any>(a0: F.NoInfer<A>, a1: F.NoInfer<A>): A => {
        return {} as unknown as A // just for the example
    }
    
    const test0 = fn0('b', 'a') // error: infer priority is `a0`
    const test1 = fn1('b', 'a') // error: infer priority is `a1`
    const test2 = fn2('b', 'a') // works: infer priority is `a0` | `a1`
    ```
    @see https://stackoverflow.com/questions/56687668
    */
    export type NoInfer<A extends any> = [
        A
    ][A extends any ? 0 : never];
}
declare module "Function/Pipe/Multi/Sync" {
    /** @ignore */ /** */
    import { Function } from "Function/Function";
    /**
    @hidden
     */
    export type PipeMultiSync = {
        <R0, P extends any[]>(...fns: [
            Function<P, R0>
        ]): Function<P, R0>;
        <R0, R1, P extends any[]>(...fns: [
            Function<P, R0>,
            Function<[R0], R1>
        ]): Function<P, R1>;
        <R0, R1, R2, P extends any[]>(...fns: [
            Function<P, R0>,
            Function<[R0], R1>,
            Function<[R1], R2>
        ]): Function<P, R2>;
        <R0, R1, R2, R3, P extends any[]>(...fns: [
            Function<P, R0>,
            Function<[R0], R1>,
            Function<[R1], R2>,
            Function<[R2], R3>
        ]): Function<P, R3>;
        <R0, R1, R2, R3, R4, P extends any[]>(...fns: [
            Function<P, R0>,
            Function<[R0], R1>,
            Function<[R1], R2>,
            Function<[R2], R3>,
            Function<[R3], R4>
        ]): Function<P, R4>;
        <R0, R1, R2, R3, R4, R5, P extends any[]>(...fns: [
            Function<P, R0>,
            Function<[R0], R1>,
            Function<[R1], R2>,
            Function<[R2], R3>,
            Function<[R3], R4>,
            Function<[R4], R5>
        ]): Function<P, R5>;
        <R0, R1, R2, R3, R4, R5, R6, P extends any[]>(...fns: [
            Function<P, R0>,
            Function<[R0], R1>,
            Function<[R1], R2>,
            Function<[R2], R3>,
            Function<[R3], R4>,
            Function<[R4], R5>,
            Function<[R5], R6>
        ]): Function<P, R6>;
        <R0, R1, R2, R3, R4, R5, R6, R7, P extends any[]>(...fns: [
            Function<P, R0>,
            Function<[R0], R1>,
            Function<[R1], R2>,
            Function<[R2], R3>,
            Function<[R3], R4>,
            Function<[R4], R5>,
            Function<[R5], R6>,
            Function<[R6], R7>
        ]): Function<P, R7>;
        <R0, R1, R2, R3, R4, R5, R6, R7, R8, P extends any[]>(...fns: [
            Function<P, R0>,
            Function<[R0], R1>,
            Function<[R1], R2>,
            Function<[R2], R3>,
            Function<[R3], R4>,
            Function<[R4], R5>,
            Function<[R5], R6>,
            Function<[R6], R7>,
            Function<[R7], R8>
        ]): Function<P, R8>;
        <R0, R1, R2, R3, R4, R5, R6, R7, R8, R9, P extends any[]>(...fns: [
            Function<P, R0>,
            Function<[R0], R1>,
            Function<[R1], R2>,
            Function<[R2], R3>,
            Function<[R3], R4>,
            Function<[R4], R5>,
            Function<[R5], R6>,
            Function<[R6], R7>,
            Function<[R7], R8>,
            Function<[R8], R9>
        ]): Function<P, R9>;
    };
}
declare module "Function/Pipe/Multi/Async" {
    /** @ignore */ /** */
    import { Function } from "Function/Function";
    import { PromiseOf } from "Any/PromiseOf";
    /**
    @hidden
     */
    export type PipeMultiAsync = {
        <R0, P extends any[]>(...fns: [
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R0>>>;
        <R0, R1, P extends any[]>(...fns: [
            Function<P, R0>,
            Function<[PromiseOf<R0>], R1>
        ]): Function<P, Promise<PromiseOf<R1>>>;
        <R0, R1, R2, P extends any[]>(...fns: [
            Function<P, R0>,
            Function<[PromiseOf<R0>], R1>,
            Function<[PromiseOf<R1>], R2>
        ]): Function<P, Promise<PromiseOf<R2>>>;
        <R0, R1, R2, R3, P extends any[]>(...fns: [
            Function<P, R0>,
            Function<[PromiseOf<R0>], R1>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R2>], R3>
        ]): Function<P, Promise<PromiseOf<R3>>>;
        <R0, R1, R2, R3, R4, P extends any[]>(...fns: [
            Function<P, R0>,
            Function<[PromiseOf<R0>], R1>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R3>], R4>
        ]): Function<P, Promise<PromiseOf<R4>>>;
        <R0, R1, R2, R3, R4, R5, P extends any[]>(...fns: [
            Function<P, R0>,
            Function<[PromiseOf<R0>], R1>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R4>], R5>
        ]): Function<P, Promise<PromiseOf<R5>>>;
        <R0, R1, R2, R3, R4, R5, R6, P extends any[]>(...fns: [
            Function<P, R0>,
            Function<[PromiseOf<R0>], R1>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R4>], R5>,
            Function<[PromiseOf<R5>], R6>
        ]): Function<P, Promise<PromiseOf<R6>>>;
        <R0, R1, R2, R3, R4, R5, R6, R7, P extends any[]>(...fns: [
            Function<P, R0>,
            Function<[PromiseOf<R0>], R1>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R4>], R5>,
            Function<[PromiseOf<R5>], R6>,
            Function<[PromiseOf<R6>], R7>
        ]): Function<P, Promise<PromiseOf<R7>>>;
        <R0, R1, R2, R3, R4, R5, R6, R7, R8, P extends any[]>(...fns: [
            Function<P, R0>,
            Function<[PromiseOf<R0>], R1>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R4>], R5>,
            Function<[PromiseOf<R5>], R6>,
            Function<[PromiseOf<R6>], R7>,
            Function<[PromiseOf<R7>], R8>
        ]): Function<P, Promise<PromiseOf<R8>>>;
        <R0, R1, R2, R3, R4, R5, R6, R7, R8, R9, P extends any[]>(...fns: [
            Function<P, R0>,
            Function<[PromiseOf<R0>], R1>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R4>], R5>,
            Function<[PromiseOf<R5>], R6>,
            Function<[PromiseOf<R6>], R7>,
            Function<[PromiseOf<R7>], R8>,
            Function<[PromiseOf<R8>], R9>
        ]): Function<P, Promise<PromiseOf<R9>>>;
    };
}
declare module "Function/Pipe/List/Sync" {
    /** @ignore */ /** */
    import { Function } from "Function/Function";
    /**
    @hidden
     */
    export type PipeListSync = {
        <R0, P extends any[]>(fns: [
            Function<P, R0>
        ]): Function<P, R0>;
        <R0, R1, P extends any[]>(fns: [
            Function<P, R0>,
            Function<[R0], R1>
        ]): Function<P, R1>;
        <R0, R1, R2, P extends any[]>(fns: [
            Function<P, R0>,
            Function<[R0], R1>,
            Function<[R1], R2>
        ]): Function<P, R2>;
        <R0, R1, R2, R3, P extends any[]>(fns: [
            Function<P, R0>,
            Function<[R0], R1>,
            Function<[R1], R2>,
            Function<[R2], R3>
        ]): Function<P, R3>;
        <R0, R1, R2, R3, R4, P extends any[]>(fns: [
            Function<P, R0>,
            Function<[R0], R1>,
            Function<[R1], R2>,
            Function<[R2], R3>,
            Function<[R3], R4>
        ]): Function<P, R4>;
        <R0, R1, R2, R3, R4, R5, P extends any[]>(fns: [
            Function<P, R0>,
            Function<[R0], R1>,
            Function<[R1], R2>,
            Function<[R2], R3>,
            Function<[R3], R4>,
            Function<[R4], R5>
        ]): Function<P, R5>;
        <R0, R1, R2, R3, R4, R5, R6, P extends any[]>(fns: [
            Function<P, R0>,
            Function<[R0], R1>,
            Function<[R1], R2>,
            Function<[R2], R3>,
            Function<[R3], R4>,
            Function<[R4], R5>,
            Function<[R5], R6>
        ]): Function<P, R6>;
        <R0, R1, R2, R3, R4, R5, R6, R7, P extends any[]>(fns: [
            Function<P, R0>,
            Function<[R0], R1>,
            Function<[R1], R2>,
            Function<[R2], R3>,
            Function<[R3], R4>,
            Function<[R4], R5>,
            Function<[R5], R6>,
            Function<[R6], R7>
        ]): Function<P, R7>;
        <R0, R1, R2, R3, R4, R5, R6, R7, R8, P extends any[]>(fns: [
            Function<P, R0>,
            Function<[R0], R1>,
            Function<[R1], R2>,
            Function<[R2], R3>,
            Function<[R3], R4>,
            Function<[R4], R5>,
            Function<[R5], R6>,
            Function<[R6], R7>,
            Function<[R7], R8>
        ]): Function<P, R8>;
        <R0, R1, R2, R3, R4, R5, R6, R7, R8, R9, P extends any[]>(fns: [
            Function<P, R0>,
            Function<[R0], R1>,
            Function<[R1], R2>,
            Function<[R2], R3>,
            Function<[R3], R4>,
            Function<[R4], R5>,
            Function<[R5], R6>,
            Function<[R6], R7>,
            Function<[R7], R8>,
            Function<[R8], R9>
        ]): Function<P, R9>;
    };
}
declare module "Function/Pipe/List/Async" {
    /** @ignore */ /** */
    import { Function } from "Function/Function";
    import { PromiseOf } from "Any/PromiseOf";
    /**
    @hidden
     */
    export type PipeListAsync = {
        <R0, P extends any[]>(fns: [
            Function<P, R0>
        ]): Function<P, Promise<PromiseOf<R0>>>;
        <R0, R1, P extends any[]>(fns: [
            Function<P, R0>,
            Function<[PromiseOf<R0>], R1>
        ]): Function<P, Promise<PromiseOf<R1>>>;
        <R0, R1, R2, P extends any[]>(fns: [
            Function<P, R0>,
            Function<[PromiseOf<R0>], R1>,
            Function<[PromiseOf<R1>], R2>
        ]): Function<P, Promise<PromiseOf<R2>>>;
        <R0, R1, R2, R3, P extends any[]>(fns: [
            Function<P, R0>,
            Function<[PromiseOf<R0>], R1>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R2>], R3>
        ]): Function<P, Promise<PromiseOf<R3>>>;
        <R0, R1, R2, R3, R4, P extends any[]>(fns: [
            Function<P, R0>,
            Function<[PromiseOf<R0>], R1>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R3>], R4>
        ]): Function<P, Promise<PromiseOf<R4>>>;
        <R0, R1, R2, R3, R4, R5, P extends any[]>(fns: [
            Function<P, R0>,
            Function<[PromiseOf<R0>], R1>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R4>], R5>
        ]): Function<P, Promise<PromiseOf<R5>>>;
        <R0, R1, R2, R3, R4, R5, R6, P extends any[]>(fns: [
            Function<P, R0>,
            Function<[PromiseOf<R0>], R1>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R4>], R5>,
            Function<[PromiseOf<R5>], R6>
        ]): Function<P, Promise<PromiseOf<R6>>>;
        <R0, R1, R2, R3, R4, R5, R6, R7, P extends any[]>(fns: [
            Function<P, R0>,
            Function<[PromiseOf<R0>], R1>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R4>], R5>,
            Function<[PromiseOf<R5>], R6>,
            Function<[PromiseOf<R6>], R7>
        ]): Function<P, Promise<PromiseOf<R7>>>;
        <R0, R1, R2, R3, R4, R5, R6, R7, R8, P extends any[]>(fns: [
            Function<P, R0>,
            Function<[PromiseOf<R0>], R1>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R4>], R5>,
            Function<[PromiseOf<R5>], R6>,
            Function<[PromiseOf<R6>], R7>,
            Function<[PromiseOf<R7>], R8>
        ]): Function<P, Promise<PromiseOf<R8>>>;
        <R0, R1, R2, R3, R4, R5, R6, R7, R8, R9, P extends any[]>(fns: [
            Function<P, R0>,
            Function<[PromiseOf<R0>], R1>,
            Function<[PromiseOf<R1>], R2>,
            Function<[PromiseOf<R2>], R3>,
            Function<[PromiseOf<R3>], R4>,
            Function<[PromiseOf<R4>], R5>,
            Function<[PromiseOf<R5>], R6>,
            Function<[PromiseOf<R6>], R7>,
            Function<[PromiseOf<R7>], R8>,
            Function<[PromiseOf<R8>], R9>
        ]): Function<P, Promise<PromiseOf<R9>>>;
    };
}
declare module "Function/Pipe" {
    import { Mode, Input } from "Function/_Internal";
    import { PipeMultiSync } from "Function/Pipe/Multi/Sync";
    import { PipeMultiAsync } from "Function/Pipe/Multi/Async";
    import { PipeListSync } from "Function/Pipe/List/Sync";
    import { PipeListAsync } from "Function/Pipe/List/Async";
    import { Function } from "Function/Function";
    import { Pos } from "Iteration/Pos";
    import { IterationOf } from "Iteration/IterationOf";
    import { Last } from "List/Last";
    import { Prev } from "Iteration/Prev";
    import { Head } from "List/Head";
    import { Return } from "Function/Return";
    import { Parameters } from "Function/Parameters";
    import { PromiseOf } from "Any/PromiseOf";
    import { Or } from "Boolean/Or";
    import { Extends } from "Any/Extends";
    import { List } from "List/List";
    import { IntersectOf } from "Union/IntersectOf";
    /**
    @hidden
    */
    type PipeFnSync<Fns extends List<Function>, K extends keyof Fns> = K extends '0' ? Fns[K] : Function<[
        Return<Fns[Pos<Prev<IterationOf<K & string>>>]> extends infer X ? {
            1: any;
            0: X;
        }[Or<Extends<unknown, X>, Extends<unknown[], X>>] : never
    ], Return<Fns[Pos<IterationOf<K & string>>]>>;
    /**
    @hidden
    */
    type PipeFnAsync<Fns extends List<Function>, K extends keyof Fns> = K extends '0' ? PromiseOf<Fns[K]> : Function<[
        PromiseOf<Return<Fns[Pos<Prev<IterationOf<K & string>>>]>> extends infer X ? {
            1: any;
            0: X;
        }[Or<Extends<unknown, X>, Extends<unknown[], X>>] : never
    ], Return<Fns[Pos<IterationOf<K & string>>]>>;
    /**
    Compute what the input of [[Pipe]] should be
    @param Fns to pipe
    @param mode (?=`'sync'`) sync/async
    @example
    ```ts
    ```
    */
    export type Piper<Fns extends List<Function>, mode extends Mode = 'sync'> = {
        'sync': {
            [K in keyof Fns]: PipeFnSync<Fns, K>;
        };
        'async': {
            [K in keyof Fns]: PipeFnAsync<Fns, K>;
        };
    }[mode];
    /**
    Pipe [[Function]]s together
    @param Fns to pipe
    @param mode (?=`'sync'`) sync/async
    @returns [[Function]]
    @example
    ```ts
    import {F} from 'ts-toolbelt'
    
    /// If you are looking for creating types for `pipe`
    /// `Piper` will check for input & `Piped` the output
    declare function pipe<Fns extends F.Function[]>(...args: F.Piper<Fns>): F.Piped<Fns>
    
    const a = (a1: number) => `${a1}`
    const b = (b1: string) => [b1]
    const c = (c1: string[]) => [c1]
    
    pipe(a, b, c)(42)
    
    /// And if you are looking for an async `pipe` type
    declare function pipe<Fns extends F.Function[]>(...args: F.Piper<Fns, 'async'>): F.Piped<Fns, 'async'>
    
    const a = async (a1: number) => `${a1}`
    const b = async (b1: string) => [b1]
    const c = async (c1: string[]) => [c1]
    
    await pipe(a, b, c)(42)
    ```
    */
    export type Piped<Fns extends List<Function>, mode extends Mode = 'sync'> = {
        'sync': (...args: Parameters<Head<Fns>>) => Return<Last<Fns>>;
        'async': (...args: Parameters<Head<Fns>>) => Promise<PromiseOf<Return<Last<Fns>>>>;
    }[mode];
    /**
    Pipe [[Function]]s together
    @param mode (?=`'sync'`) sync/async (this depends on your implementation)
    @param input (?=`'multi'`) whether you want to take a list or multiple parameters
    @returns [[Function]]
    @example
    ```ts
    import {F} from 'ts-toolbelt'
    
    /// If you are looking for creating types for `pipe`:
    declare const pipe: F.Pipe
    
    const a = (a1: number) => `${a1}`
    const b = (b1: string) => [b1]
    const c = (c1: string[]) => [c1]
    
    pipe(a, b, c)(42)
    
    /// And if you are looking for an async `pipe` type:
    declare const pipe: F.Pipe<'async'>
    
    const a = async (a1: number) => `${a1}`
    const b = async (b1: string) => [b1]
    const c = async (c1: string[]) => [c1]
    
    await pipe(a, b, c)(42)
    ```
    */
    export type Pipe<mode extends Mode = 'sync', input extends Input = 'multi'> = IntersectOf<{
        'sync': {
            'multi': PipeMultiSync;
            'list': PipeListSync;
        };
        'async': {
            'multi': PipeMultiAsync;
            'list': PipeListAsync;
        };
    }[mode][input]>;
}
declare module "Function/Promisify" {
    import { Function } from "Function/Function";
    import { Parameters } from "Function/Parameters";
    import { Return } from "Function/Return";
    import { Promise } from "Any/Promise";
    /**
    Creates a promisified version of a **`Function`** **`F`**
    @param F to promisify
    @returns async F
    @example
    ```ts
    import {F} from 'ts-toolbelt'
    
    type test0 = F.Promisify<(a: number) => number> // (a: number) => Promise<number>
    ```
    */
    export type Promisify<F extends Function> = (...args: Parameters<F>) => Promise<Return<F>>;
}
declare module "Function/UnCurry" {
    import { Curry } from "Function/Curry";
    /**
    Undoes the work that was done by [[Curry]]
    @param F to uncurry
    @returns [[Function]]
    @example
    @ignore
    */
    export type UnCurry<F extends Curry<any>> = F extends Curry<infer UF> ? UF : never;
}
declare module "Function/_api" {
    /** @ignore */ /** */
    export { Compose, Composed, Composer } from "Function/Compose";
    export { Curry } from "Function/Curry";
    export { Function } from "Function/Function";
    export { Length } from "Function/Length";
    export { NoInfer } from "Function/NoInfer";
    export { Parameters } from "Function/Parameters";
    export { Pipe, Piped, Piper } from "Function/Pipe";
    export { Promisify } from "Function/Promisify";
    export { Return } from "Function/Return";
    export { UnCurry } from "Function/UnCurry";
}
declare module "Iteration/Maps/Pixel" {
    import { CreateMap } from "Iteration/Map";
    /**
     * @hidden
     */
    type RawMap = {
        '-100px': ['__', '-99px', '-100px', -100, '100px', '-100px', '-'];
        '-99px': ['-100px', '-98px', '-99px', -99, '99px', RawMap['-100px'][5] | '-99px', '-'];
        '-98px': ['-99px', '-97px', '-98px', -98, '98px', RawMap['-99px'][5] | '-98px', '-'];
        '-97px': ['-98px', '-96px', '-97px', -97, '97px', RawMap['-98px'][5] | '-97px', '-'];
        '-96px': ['-97px', '-95px', '-96px', -96, '96px', RawMap['-97px'][5] | '-96px', '-'];
        '-95px': ['-96px', '-94px', '-95px', -95, '95px', RawMap['-96px'][5] | '-95px', '-'];
        '-94px': ['-95px', '-93px', '-94px', -94, '94px', RawMap['-95px'][5] | '-94px', '-'];
        '-93px': ['-94px', '-92px', '-93px', -93, '93px', RawMap['-94px'][5] | '-93px', '-'];
        '-92px': ['-93px', '-91px', '-92px', -92, '92px', RawMap['-93px'][5] | '-92px', '-'];
        '-91px': ['-92px', '-90px', '-91px', -91, '91px', RawMap['-92px'][5] | '-91px', '-'];
        '-90px': ['-91px', '-89px', '-90px', -90, '90px', RawMap['-91px'][5] | '-90px', '-'];
        '-89px': ['-90px', '-88px', '-89px', -89, '89px', RawMap['-90px'][5] | '-89px', '-'];
        '-88px': ['-89px', '-87px', '-88px', -88, '88px', RawMap['-89px'][5] | '-88px', '-'];
        '-87px': ['-88px', '-86px', '-87px', -87, '87px', RawMap['-88px'][5] | '-87px', '-'];
        '-86px': ['-87px', '-85px', '-86px', -86, '86px', RawMap['-87px'][5] | '-86px', '-'];
        '-85px': ['-86px', '-84px', '-85px', -85, '85px', RawMap['-86px'][5] | '-85px', '-'];
        '-84px': ['-85px', '-83px', '-84px', -84, '84px', RawMap['-85px'][5] | '-84px', '-'];
        '-83px': ['-84px', '-82px', '-83px', -83, '83px', RawMap['-84px'][5] | '-83px', '-'];
        '-82px': ['-83px', '-81px', '-82px', -82, '82px', RawMap['-83px'][5] | '-82px', '-'];
        '-81px': ['-82px', '-80px', '-81px', -81, '81px', RawMap['-82px'][5] | '-81px', '-'];
        '-80px': ['-81px', '-79px', '-80px', -80, '80px', RawMap['-81px'][5] | '-80px', '-'];
        '-79px': ['-80px', '-78px', '-79px', -79, '79px', RawMap['-80px'][5] | '-79px', '-'];
        '-78px': ['-79px', '-77px', '-78px', -78, '78px', RawMap['-79px'][5] | '-78px', '-'];
        '-77px': ['-78px', '-76px', '-77px', -77, '77px', RawMap['-78px'][5] | '-77px', '-'];
        '-76px': ['-77px', '-75px', '-76px', -76, '76px', RawMap['-77px'][5] | '-76px', '-'];
        '-75px': ['-76px', '-74px', '-75px', -75, '75px', RawMap['-76px'][5] | '-75px', '-'];
        '-74px': ['-75px', '-73px', '-74px', -74, '74px', RawMap['-75px'][5] | '-74px', '-'];
        '-73px': ['-74px', '-72px', '-73px', -73, '73px', RawMap['-74px'][5] | '-73px', '-'];
        '-72px': ['-73px', '-71px', '-72px', -72, '72px', RawMap['-73px'][5] | '-72px', '-'];
        '-71px': ['-72px', '-70px', '-71px', -71, '71px', RawMap['-72px'][5] | '-71px', '-'];
        '-70px': ['-71px', '-69px', '-70px', -70, '70px', RawMap['-71px'][5] | '-70px', '-'];
        '-69px': ['-70px', '-68px', '-69px', -69, '69px', RawMap['-70px'][5] | '-69px', '-'];
        '-68px': ['-69px', '-67px', '-68px', -68, '68px', RawMap['-69px'][5] | '-68px', '-'];
        '-67px': ['-68px', '-66px', '-67px', -67, '67px', RawMap['-68px'][5] | '-67px', '-'];
        '-66px': ['-67px', '-65px', '-66px', -66, '66px', RawMap['-67px'][5] | '-66px', '-'];
        '-65px': ['-66px', '-64px', '-65px', -65, '65px', RawMap['-66px'][5] | '-65px', '-'];
        '-64px': ['-65px', '-63px', '-64px', -64, '64px', RawMap['-65px'][5] | '-64px', '-'];
        '-63px': ['-64px', '-62px', '-63px', -63, '63px', RawMap['-64px'][5] | '-63px', '-'];
        '-62px': ['-63px', '-61px', '-62px', -62, '62px', RawMap['-63px'][5] | '-62px', '-'];
        '-61px': ['-62px', '-60px', '-61px', -61, '61px', RawMap['-62px'][5] | '-61px', '-'];
        '-60px': ['-61px', '-59px', '-60px', -60, '60px', RawMap['-61px'][5] | '-60px', '-'];
        '-59px': ['-60px', '-58px', '-59px', -59, '59px', RawMap['-60px'][5] | '-59px', '-'];
        '-58px': ['-59px', '-57px', '-58px', -58, '58px', RawMap['-59px'][5] | '-58px', '-'];
        '-57px': ['-58px', '-56px', '-57px', -57, '57px', RawMap['-58px'][5] | '-57px', '-'];
        '-56px': ['-57px', '-55px', '-56px', -56, '56px', RawMap['-57px'][5] | '-56px', '-'];
        '-55px': ['-56px', '-54px', '-55px', -55, '55px', RawMap['-56px'][5] | '-55px', '-'];
        '-54px': ['-55px', '-53px', '-54px', -54, '54px', RawMap['-55px'][5] | '-54px', '-'];
        '-53px': ['-54px', '-52px', '-53px', -53, '53px', RawMap['-54px'][5] | '-53px', '-'];
        '-52px': ['-53px', '-51px', '-52px', -52, '52px', RawMap['-53px'][5] | '-52px', '-'];
        '-51px': ['-52px', '-50px', '-51px', -51, '51px', RawMap['-52px'][5] | '-51px', '-'];
        '-50px': ['-51px', '-49px', '-50px', -50, '50px', RawMap['-51px'][5] | '-50px', '-'];
        '-49px': ['-50px', '-48px', '-49px', -49, '49px', RawMap['-50px'][5] | '-49px', '-'];
        '-48px': ['-49px', '-47px', '-48px', -48, '48px', RawMap['-49px'][5] | '-48px', '-'];
        '-47px': ['-48px', '-46px', '-47px', -47, '47px', RawMap['-48px'][5] | '-47px', '-'];
        '-46px': ['-47px', '-45px', '-46px', -46, '46px', RawMap['-47px'][5] | '-46px', '-'];
        '-45px': ['-46px', '-44px', '-45px', -45, '45px', RawMap['-46px'][5] | '-45px', '-'];
        '-44px': ['-45px', '-43px', '-44px', -44, '44px', RawMap['-45px'][5] | '-44px', '-'];
        '-43px': ['-44px', '-42px', '-43px', -43, '43px', RawMap['-44px'][5] | '-43px', '-'];
        '-42px': ['-43px', '-41px', '-42px', -42, '42px', RawMap['-43px'][5] | '-42px', '-'];
        '-41px': ['-42px', '-40px', '-41px', -41, '41px', RawMap['-42px'][5] | '-41px', '-'];
        '-40px': ['-41px', '-39px', '-40px', -40, '40px', RawMap['-41px'][5] | '-40px', '-'];
        '-39px': ['-40px', '-38px', '-39px', -39, '39px', RawMap['-40px'][5] | '-39px', '-'];
        '-38px': ['-39px', '-37px', '-38px', -38, '38px', RawMap['-39px'][5] | '-38px', '-'];
        '-37px': ['-38px', '-36px', '-37px', -37, '37px', RawMap['-38px'][5] | '-37px', '-'];
        '-36px': ['-37px', '-35px', '-36px', -36, '36px', RawMap['-37px'][5] | '-36px', '-'];
        '-35px': ['-36px', '-34px', '-35px', -35, '35px', RawMap['-36px'][5] | '-35px', '-'];
        '-34px': ['-35px', '-33px', '-34px', -34, '34px', RawMap['-35px'][5] | '-34px', '-'];
        '-33px': ['-34px', '-32px', '-33px', -33, '33px', RawMap['-34px'][5] | '-33px', '-'];
        '-32px': ['-33px', '-31px', '-32px', -32, '32px', RawMap['-33px'][5] | '-32px', '-'];
        '-31px': ['-32px', '-30px', '-31px', -31, '31px', RawMap['-32px'][5] | '-31px', '-'];
        '-30px': ['-31px', '-29px', '-30px', -30, '30px', RawMap['-31px'][5] | '-30px', '-'];
        '-29px': ['-30px', '-28px', '-29px', -29, '29px', RawMap['-30px'][5] | '-29px', '-'];
        '-28px': ['-29px', '-27px', '-28px', -28, '28px', RawMap['-29px'][5] | '-28px', '-'];
        '-27px': ['-28px', '-26px', '-27px', -27, '27px', RawMap['-28px'][5] | '-27px', '-'];
        '-26px': ['-27px', '-25px', '-26px', -26, '26px', RawMap['-27px'][5] | '-26px', '-'];
        '-25px': ['-26px', '-24px', '-25px', -25, '25px', RawMap['-26px'][5] | '-25px', '-'];
        '-24px': ['-25px', '-23px', '-24px', -24, '24px', RawMap['-25px'][5] | '-24px', '-'];
        '-23px': ['-24px', '-22px', '-23px', -23, '23px', RawMap['-24px'][5] | '-23px', '-'];
        '-22px': ['-23px', '-21px', '-22px', -22, '22px', RawMap['-23px'][5] | '-22px', '-'];
        '-21px': ['-22px', '-20px', '-21px', -21, '21px', RawMap['-22px'][5] | '-21px', '-'];
        '-20px': ['-21px', '-19px', '-20px', -20, '20px', RawMap['-21px'][5] | '-20px', '-'];
        '-19px': ['-20px', '-18px', '-19px', -19, '19px', RawMap['-20px'][5] | '-19px', '-'];
        '-18px': ['-19px', '-17px', '-18px', -18, '18px', RawMap['-19px'][5] | '-18px', '-'];
        '-17px': ['-18px', '-16px', '-17px', -17, '17px', RawMap['-18px'][5] | '-17px', '-'];
        '-16px': ['-17px', '-15px', '-16px', -16, '16px', RawMap['-17px'][5] | '-16px', '-'];
        '-15px': ['-16px', '-14px', '-15px', -15, '15px', RawMap['-16px'][5] | '-15px', '-'];
        '-14px': ['-15px', '-13px', '-14px', -14, '14px', RawMap['-15px'][5] | '-14px', '-'];
        '-13px': ['-14px', '-12px', '-13px', -13, '13px', RawMap['-14px'][5] | '-13px', '-'];
        '-12px': ['-13px', '-11px', '-12px', -12, '12px', RawMap['-13px'][5] | '-12px', '-'];
        '-11px': ['-12px', '-10px', '-11px', -11, '11px', RawMap['-12px'][5] | '-11px', '-'];
        '-10px': ['-11px', '-9px', '-10px', -10, '10px', RawMap['-11px'][5] | '-10px', '-'];
        '-9px': ['-10px', '-8px', '-9px', -9, '9px', RawMap['-10px'][5] | '-9px', '-'];
        '-8px': ['-9px', '-7px', '-8px', -8, '8px', RawMap['-9px'][5] | '-8px', '-'];
        '-7px': ['-8px', '-6px', '-7px', -7, '7px', RawMap['-8px'][5] | '-7px', '-'];
        '-6px': ['-7px', '-5px', '-6px', -6, '6px', RawMap['-7px'][5] | '-6px', '-'];
        '-5px': ['-6px', '-4px', '-5px', -5, '5px', RawMap['-6px'][5] | '-5px', '-'];
        '-4px': ['-5px', '-3px', '-4px', -4, '4px', RawMap['-5px'][5] | '-4px', '-'];
        '-3px': ['-4px', '-2px', '-3px', -3, '3px', RawMap['-4px'][5] | '-3px', '-'];
        '-2px': ['-3px', '-1px', '-2px', -2, '2px', RawMap['-3px'][5] | '-2px', '-'];
        '-1px': ['-2px', '0px', '-1px', -1, '1px', RawMap['-2px'][5] | '-1px', '-'];
        '0': ['-1px', '1px', '0px', 0, '0px', RawMap['-1px'][5] | '0px', '0'];
        '0px': ['-1px', '1px', '0px', 0, '0px', RawMap['-1px'][5] | '0px', '0'];
        '1px': ['0px', '2px', '1px', 1, '-1px', RawMap['0px'][5] | '1px', '+'];
        '2px': ['1px', '3px', '2px', 2, '-2px', RawMap['1px'][5] | '2px', '+'];
        '3px': ['2px', '4px', '3px', 3, '-3px', RawMap['2px'][5] | '3px', '+'];
        '4px': ['3px', '5px', '4px', 4, '-4px', RawMap['3px'][5] | '4px', '+'];
        '5px': ['4px', '6px', '5px', 5, '-5px', RawMap['4px'][5] | '5px', '+'];
        '6px': ['5px', '7px', '6px', 6, '-6px', RawMap['5px'][5] | '6px', '+'];
        '7px': ['6px', '8px', '7px', 7, '-7px', RawMap['6px'][5] | '7px', '+'];
        '8px': ['7px', '9px', '8px', 8, '-8px', RawMap['7px'][5] | '8px', '+'];
        '9px': ['8px', '10px', '9px', 9, '-9px', RawMap['8px'][5] | '9px', '+'];
        '10px': ['9px', '11px', '10px', 10, '-10px', RawMap['9px'][5] | '10px', '+'];
        '11px': ['10px', '12px', '11px', 11, '-11px', RawMap['10px'][5] | '11px', '+'];
        '12px': ['11px', '13px', '12px', 12, '-12px', RawMap['11px'][5] | '12px', '+'];
        '13px': ['12px', '14px', '13px', 13, '-13px', RawMap['12px'][5] | '13px', '+'];
        '14px': ['13px', '15px', '14px', 14, '-14px', RawMap['13px'][5] | '14px', '+'];
        '15px': ['14px', '16px', '15px', 15, '-15px', RawMap['14px'][5] | '15px', '+'];
        '16px': ['15px', '17px', '16px', 16, '-16px', RawMap['15px'][5] | '16px', '+'];
        '17px': ['16px', '18px', '17px', 17, '-17px', RawMap['16px'][5] | '17px', '+'];
        '18px': ['17px', '19px', '18px', 18, '-18px', RawMap['17px'][5] | '18px', '+'];
        '19px': ['18px', '20px', '19px', 19, '-19px', RawMap['18px'][5] | '19px', '+'];
        '20px': ['19px', '21px', '20px', 20, '-20px', RawMap['19px'][5] | '20px', '+'];
        '21px': ['20px', '22px', '21px', 21, '-21px', RawMap['20px'][5] | '21px', '+'];
        '22px': ['21px', '23px', '22px', 22, '-22px', RawMap['21px'][5] | '22px', '+'];
        '23px': ['22px', '24px', '23px', 23, '-23px', RawMap['22px'][5] | '23px', '+'];
        '24px': ['23px', '25px', '24px', 24, '-24px', RawMap['23px'][5] | '24px', '+'];
        '25px': ['24px', '26px', '25px', 25, '-25px', RawMap['24px'][5] | '25px', '+'];
        '26px': ['25px', '27px', '26px', 26, '-26px', RawMap['25px'][5] | '26px', '+'];
        '27px': ['26px', '28px', '27px', 27, '-27px', RawMap['26px'][5] | '27px', '+'];
        '28px': ['27px', '29px', '28px', 28, '-28px', RawMap['27px'][5] | '28px', '+'];
        '29px': ['28px', '30px', '29px', 29, '-29px', RawMap['28px'][5] | '29px', '+'];
        '30px': ['29px', '31px', '30px', 30, '-30px', RawMap['29px'][5] | '30px', '+'];
        '31px': ['30px', '32px', '31px', 31, '-31px', RawMap['30px'][5] | '31px', '+'];
        '32px': ['31px', '33px', '32px', 32, '-32px', RawMap['31px'][5] | '32px', '+'];
        '33px': ['32px', '34px', '33px', 33, '-33px', RawMap['32px'][5] | '33px', '+'];
        '34px': ['33px', '35px', '34px', 34, '-34px', RawMap['33px'][5] | '34px', '+'];
        '35px': ['34px', '36px', '35px', 35, '-35px', RawMap['34px'][5] | '35px', '+'];
        '36px': ['35px', '37px', '36px', 36, '-36px', RawMap['35px'][5] | '36px', '+'];
        '37px': ['36px', '38px', '37px', 37, '-37px', RawMap['36px'][5] | '37px', '+'];
        '38px': ['37px', '39px', '38px', 38, '-38px', RawMap['37px'][5] | '38px', '+'];
        '39px': ['38px', '40px', '39px', 39, '-39px', RawMap['38px'][5] | '39px', '+'];
        '40px': ['39px', '41px', '40px', 40, '-40px', RawMap['39px'][5] | '40px', '+'];
        '41px': ['40px', '42px', '41px', 41, '-41px', RawMap['40px'][5] | '41px', '+'];
        '42px': ['41px', '43px', '42px', 42, '-42px', RawMap['41px'][5] | '42px', '+'];
        '43px': ['42px', '44px', '43px', 43, '-43px', RawMap['42px'][5] | '43px', '+'];
        '44px': ['43px', '45px', '44px', 44, '-44px', RawMap['43px'][5] | '44px', '+'];
        '45px': ['44px', '46px', '45px', 45, '-45px', RawMap['44px'][5] | '45px', '+'];
        '46px': ['45px', '47px', '46px', 46, '-46px', RawMap['45px'][5] | '46px', '+'];
        '47px': ['46px', '48px', '47px', 47, '-47px', RawMap['46px'][5] | '47px', '+'];
        '48px': ['47px', '49px', '48px', 48, '-48px', RawMap['47px'][5] | '48px', '+'];
        '49px': ['48px', '50px', '49px', 49, '-49px', RawMap['48px'][5] | '49px', '+'];
        '50px': ['49px', '51px', '50px', 50, '-50px', RawMap['49px'][5] | '50px', '+'];
        '51px': ['50px', '52px', '51px', 51, '-51px', RawMap['50px'][5] | '51px', '+'];
        '52px': ['51px', '53px', '52px', 52, '-52px', RawMap['51px'][5] | '52px', '+'];
        '53px': ['52px', '54px', '53px', 53, '-53px', RawMap['52px'][5] | '53px', '+'];
        '54px': ['53px', '55px', '54px', 54, '-54px', RawMap['53px'][5] | '54px', '+'];
        '55px': ['54px', '56px', '55px', 55, '-55px', RawMap['54px'][5] | '55px', '+'];
        '56px': ['55px', '57px', '56px', 56, '-56px', RawMap['55px'][5] | '56px', '+'];
        '57px': ['56px', '58px', '57px', 57, '-57px', RawMap['56px'][5] | '57px', '+'];
        '58px': ['57px', '59px', '58px', 58, '-58px', RawMap['57px'][5] | '58px', '+'];
        '59px': ['58px', '60px', '59px', 59, '-59px', RawMap['58px'][5] | '59px', '+'];
        '60px': ['59px', '61px', '60px', 60, '-60px', RawMap['59px'][5] | '60px', '+'];
        '61px': ['60px', '62px', '61px', 61, '-61px', RawMap['60px'][5] | '61px', '+'];
        '62px': ['61px', '63px', '62px', 62, '-62px', RawMap['61px'][5] | '62px', '+'];
        '63px': ['62px', '64px', '63px', 63, '-63px', RawMap['62px'][5] | '63px', '+'];
        '64px': ['63px', '65px', '64px', 64, '-64px', RawMap['63px'][5] | '64px', '+'];
        '65px': ['64px', '66px', '65px', 65, '-65px', RawMap['64px'][5] | '65px', '+'];
        '66px': ['65px', '67px', '66px', 66, '-66px', RawMap['65px'][5] | '66px', '+'];
        '67px': ['66px', '68px', '67px', 67, '-67px', RawMap['66px'][5] | '67px', '+'];
        '68px': ['67px', '69px', '68px', 68, '-68px', RawMap['67px'][5] | '68px', '+'];
        '69px': ['68px', '70px', '69px', 69, '-69px', RawMap['68px'][5] | '69px', '+'];
        '70px': ['69px', '71px', '70px', 70, '-70px', RawMap['69px'][5] | '70px', '+'];
        '71px': ['70px', '72px', '71px', 71, '-71px', RawMap['70px'][5] | '71px', '+'];
        '72px': ['71px', '73px', '72px', 72, '-72px', RawMap['71px'][5] | '72px', '+'];
        '73px': ['72px', '74px', '73px', 73, '-73px', RawMap['72px'][5] | '73px', '+'];
        '74px': ['73px', '75px', '74px', 74, '-74px', RawMap['73px'][5] | '74px', '+'];
        '75px': ['74px', '76px', '75px', 75, '-75px', RawMap['74px'][5] | '75px', '+'];
        '76px': ['75px', '77px', '76px', 76, '-76px', RawMap['75px'][5] | '76px', '+'];
        '77px': ['76px', '78px', '77px', 77, '-77px', RawMap['76px'][5] | '77px', '+'];
        '78px': ['77px', '79px', '78px', 78, '-78px', RawMap['77px'][5] | '78px', '+'];
        '79px': ['78px', '80px', '79px', 79, '-79px', RawMap['78px'][5] | '79px', '+'];
        '80px': ['79px', '81px', '80px', 80, '-80px', RawMap['79px'][5] | '80px', '+'];
        '81px': ['80px', '82px', '81px', 81, '-81px', RawMap['80px'][5] | '81px', '+'];
        '82px': ['81px', '83px', '82px', 82, '-82px', RawMap['81px'][5] | '82px', '+'];
        '83px': ['82px', '84px', '83px', 83, '-83px', RawMap['82px'][5] | '83px', '+'];
        '84px': ['83px', '85px', '84px', 84, '-84px', RawMap['83px'][5] | '84px', '+'];
        '85px': ['84px', '86px', '85px', 85, '-85px', RawMap['84px'][5] | '85px', '+'];
        '86px': ['85px', '87px', '86px', 86, '-86px', RawMap['85px'][5] | '86px', '+'];
        '87px': ['86px', '88px', '87px', 87, '-87px', RawMap['86px'][5] | '87px', '+'];
        '88px': ['87px', '89px', '88px', 88, '-88px', RawMap['87px'][5] | '88px', '+'];
        '89px': ['88px', '90px', '89px', 89, '-89px', RawMap['88px'][5] | '89px', '+'];
        '90px': ['89px', '91px', '90px', 90, '-90px', RawMap['89px'][5] | '90px', '+'];
        '91px': ['90px', '92px', '91px', 91, '-91px', RawMap['90px'][5] | '91px', '+'];
        '92px': ['91px', '93px', '92px', 92, '-92px', RawMap['91px'][5] | '92px', '+'];
        '93px': ['92px', '94px', '93px', 93, '-93px', RawMap['92px'][5] | '93px', '+'];
        '94px': ['93px', '95px', '94px', 94, '-94px', RawMap['93px'][5] | '94px', '+'];
        '95px': ['94px', '96px', '95px', 95, '-95px', RawMap['94px'][5] | '95px', '+'];
        '96px': ['95px', '97px', '96px', 96, '-96px', RawMap['95px'][5] | '96px', '+'];
        '97px': ['96px', '98px', '97px', 97, '-97px', RawMap['96px'][5] | '97px', '+'];
        '98px': ['97px', '99px', '98px', 98, '-98px', RawMap['97px'][5] | '98px', '+'];
        '99px': ['98px', '100px', '99px', 99, '-99px', RawMap['98px'][5] | '99px', '+'];
        '100px': ['99px', '__', '100px', 100, '-100px', RawMap['99px'][5] | '100px', '+'];
    };
    /**
     * @hidden
     */
    type MapKeys = {
        '-': '-100px' | '-99px' | '-98px' | '-97px' | '-96px' | '-95px' | '-94px' | '-93px' | '-92px' | '-91px' | '-90px' | '-89px' | '-88px' | '-87px' | '-86px' | '-85px' | '-84px' | '-83px' | '-82px' | '-81px' | '-80px' | '-79px' | '-78px' | '-77px' | '-76px' | '-75px' | '-74px' | '-73px' | '-72px' | '-71px' | '-70px' | '-69px' | '-68px' | '-67px' | '-66px' | '-65px' | '-64px' | '-63px' | '-62px' | '-61px' | '-60px' | '-59px' | '-58px' | '-57px' | '-56px' | '-55px' | '-54px' | '-53px' | '-52px' | '-51px' | '-50px' | '-49px' | '-48px' | '-47px' | '-46px' | '-45px' | '-44px' | '-43px' | '-42px' | '-41px' | '-40px' | '-39px' | '-38px' | '-37px' | '-36px' | '-35px' | '-34px' | '-33px' | '-32px' | '-31px' | '-30px' | '-29px' | '-28px' | '-27px' | '-26px' | '-25px' | '-24px' | '-23px' | '-22px' | '-21px' | '-20px' | '-19px' | '-18px' | '-17px' | '-16px' | '-15px' | '-14px' | '-13px' | '-12px' | '-11px' | '-10px' | '-9px' | '-8px' | '-7px' | '-6px' | '-5px' | '-4px' | '-3px' | '-2px' | '-1px';
        '0': '0px';
        '+': '1px' | '2px' | '3px' | '4px' | '5px' | '6px' | '7px' | '8px' | '9px' | '10px' | '11px' | '12px' | '13px' | '14px' | '15px' | '16px' | '17px' | '18px' | '19px' | '20px' | '21px' | '22px' | '23px' | '24px' | '25px' | '26px' | '27px' | '28px' | '29px' | '30px' | '31px' | '32px' | '33px' | '34px' | '35px' | '36px' | '37px' | '38px' | '39px' | '40px' | '41px' | '42px' | '43px' | '44px' | '45px' | '46px' | '47px' | '48px' | '49px' | '50px' | '51px' | '52px' | '53px' | '54px' | '55px' | '56px' | '57px' | '58px' | '59px' | '60px' | '61px' | '62px' | '63px' | '64px' | '65px' | '66px' | '67px' | '68px' | '69px' | '70px' | '71px' | '72px' | '73px' | '74px' | '75px' | '76px' | '77px' | '78px' | '79px' | '80px' | '81px' | '82px' | '83px' | '84px' | '85px' | '86px' | '87px' | '88px' | '89px' | '90px' | '91px' | '92px' | '93px' | '94px' | '95px' | '96px' | '97px' | '98px' | '99px' | '100px';
    };
    /**
    Describes a map of pixel relationships
    */
    export type PixelMap = CreateMap<MapKeys, RawMap>;
}
declare module "Iteration/Maps/_api" {
    /** @ignore */ /** */
    export { NumberMap as Number } from "Iteration/Maps/Number";
    export { PixelMap as Pixel } from "Iteration/Maps/Pixel";
}
declare module "Iteration/_api" {
    /** @ignore */ /** */
    import * as Maps from "Iteration/Maps/_api";
    export { Maps };
    export { Format } from "Iteration/Format";
    export { Iteration } from "Iteration/Iteration";
    export { IterationOf } from "Iteration/IterationOf";
    export { Key } from "Iteration/Key";
    export { Next } from "Iteration/Next";
    export { Pos } from "Iteration/Pos";
    export { Prev } from "Iteration/Prev";
}
declare module "Misc/JSON/Primitive" {
    /**
    Basic JSON Value
    */
    export type Primitive = string | number | boolean | null;
}
declare module "Misc/JSON/Object" {
    import { Value } from "Misc/JSON/Value";
    /**
    An object of JSON [[Value]]s
    */
    export interface Object {
        [k: string]: Value;
    }
}
declare module "Misc/JSON/Value" {
    import { Primitive } from "Misc/JSON/Primitive";
    import { List } from "Misc/JSON/Array";
    import { Object } from "Misc/JSON/Object";
    /**
    Any JSON data/value
    */
    export type Value = Primitive | Object | List;
}
declare module "Misc/JSON/Array" {
    import { Value } from "Misc/JSON/Value";
    /**
    A list of JSON [[Value]]s
    */
    export interface List extends Array<Value> {
    }
}
declare module "Misc/JSON/_api" {
    /** @ignore */ /** */
    export { List as Array } from "Misc/JSON/Array";
    export { Object } from "Misc/JSON/Object";
    export { Primitive } from "Misc/JSON/Primitive";
    export { Value } from "Misc/JSON/Value";
}
declare module "Misc/Primitive" {
    /**
     * All primitive types
     */
    export type Primitive = boolean | string | number | bigint | symbol | undefined | null;
}
declare module "Misc/_api" {
    /** @ignore */ /** */
    import * as JSON from "Misc/JSON/_api";
    export { JSON };
    export { BuiltInObject } from "Misc/BuiltInObject";
    export { Primitive } from "Misc/Primitive";
    import * as Iteration from "Iteration/Maps/_api";
    export { Iteration };
    export { Promisable } from "Any/Promisable";
}
declare module "Number/IsNegative" {
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Number } from "Number/Number";
    import { NumberMap } from "Iteration/Maps/Number";
    import { Map } from "Iteration/Map";
    /**
    @hidden
    */
    export type _IsNegative<N extends Iteration> = {
        '-': 1;
        '+': 0;
        '0': 0;
    }[N[6]];
    /**
    Check whether a [[Number]] is negative or not
    @param N to check
    @returns [[Boolean]]
    @example
    ```ts
    import {N} from 'ts-toolbelt'
    
    type test0 = N.IsNegative<'0'>  // False
    type test1 = N.IsNegative<'-7'> // True
    type test2 = N.IsNegative<'7'>  // False
    ```
    */
    export type IsNegative<N extends Number, IMap extends Map = NumberMap> = _IsNegative<IterationOf<N, IMap>>;
}
declare module "Number/Minus" {
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Pos } from "Iteration/Pos";
    import { Prev } from "Iteration/Prev";
    import { Next } from "Iteration/Next";
    import { _IsNegative } from "Number/IsNegative";
    import { Cast } from "Any/Cast";
    import { Number } from "Number/Number";
    import { Formats } from "Iteration/_Internal";
    import { Format } from "Iteration/Format";
    import { NumberMap } from "Iteration/Maps/Number";
    import { Map } from "Iteration/Map";
    /**
    @hidden
    */
    type _MinusPositive<N1 extends Iteration, N2 extends Iteration, IMap extends Map> = {
        0: _MinusPositive<Prev<N1, IMap>, Prev<N2, IMap>, IMap>;
        1: N1;
        2: N2;
    }[Pos<N2> extends 0 ? 1 : number extends Pos<N2> ? 2 : 0];
    /**
    @hidden
    */
    type MinusPositive<N1 extends Iteration, N2 extends Iteration, IMap extends Map> = _MinusPositive<N1, N2, IMap> extends infer X ? Cast<X, Iteration> : never;
    /**
    @hidden
    */
    type _MinusNegative<N1 extends Iteration, N2 extends Iteration, IMap extends Map> = {
        0: _MinusNegative<Next<N1, IMap>, Next<N2, IMap>, IMap>;
        1: N1;
        2: N2;
    }[Pos<N2> extends 0 ? 1 : number extends Pos<N2> ? 2 : 0];
    /**
    @hidden
    */
    type MinusNegative<N1 extends Iteration, N2 extends Iteration, IMap extends Map> = _MinusNegative<N1, N2, IMap> extends infer X ? Cast<X, Iteration> : never;
    /**
    @hidden
    */
    export type _Minus<N1 extends Iteration, N2 extends Iteration, IMap extends Map> = {
        0: MinusPositive<N1, N2, IMap>;
        1: MinusNegative<N1, N2, IMap>;
    }[_IsNegative<N2>];
    /**
    @hidden
    */
    export type __Minus<N1 extends Number, N2 extends Number, fmt extends Formats, IMap extends Map> = Format<_Minus<IterationOf<N1, IMap>, IterationOf<N2, IMap>, IMap>, fmt>;
    /**
    Subtract a [[Number]] from another one
    @param N1 Left-hand side
    @param N2 Right-hand side
    @param fmt (?=`'s'`) output format
    @param IMap to operate with another set of numbers
    @returns **`string | number | boolean`**
    @example
    ```ts
    import {N} from 'ts-toolbelt'
    
    type test0 = N.Minus<'2', '10'>        // '-8'
    type test1 = N.Minus<'0', '40'>        // '-40'
    type test2 = N.Minus<'0', '40', 's'>   // '-40'
    type test3 = N.Minus<'0', '40', 'n'>   //  -40
    type test4 = N.Minus<'-20', '40', 's'> // string
    type test5 = N.Minus<'-20', '40', 'n'> // number
    ```
    */
    export type Minus<N1 extends Number, N2 extends Number, fmt extends Formats = 's', IMap extends Map = NumberMap> = N1 extends unknown ? N2 extends unknown ? __Minus<N1, N2, fmt, IMap> : never : never;
}
declare module "Number/Negate" {
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Number } from "Number/Number";
    import { Formats } from "Iteration/_Internal";
    import { Format } from "Iteration/Format";
    import { NumberMap } from "Iteration/Maps/Number";
    import { Map } from "Iteration/Map";
    /**
    @hidden
    */
    export type _Negate<N extends Iteration, IMap extends Map> = IterationOf<N[4], IMap>;
    /**
    Negate a [[Number]]
    @param N to negate
    @param fmt (?=`'s'`) output format
    @param IMap to operate with another set of numbers
    @returns **`string | number | boolean`**
    @example
    ```ts
    import {N} from 'ts-toolbelt'
    
    type test0 = N.Negate<'-10'>     //  '10'
    type test1 = N.Negate<'10'>      // '-10'
    type test2 = N.Negate<'10', 's'> // '-10'
    type test3 = N.Negate<'10', 'n'> //  -10
    type test4 = N.Negate<'-100'>    // string
    ```
    */
    export type Negate<N extends Number, fmt extends Formats = 's', IMap extends Map = NumberMap> = N extends unknown ? Format<_Negate<IterationOf<N, IMap>, IMap>, fmt> : never;
}
declare module "Number/Absolute" {
    import { _Negate } from "Number/Negate";
    import { _IsNegative } from "Number/IsNegative";
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Number } from "Number/Number";
    import { Formats } from "Iteration/_Internal";
    import { Format } from "Iteration/Format";
    import { NumberMap } from "Iteration/Maps/Number";
    import { Map } from "Iteration/Map";
    /**
    @hidden
    */
    export type _Absolute<N extends Iteration, IMap extends Map> = {
        0: N;
        1: _Negate<N, IMap>;
    }[_IsNegative<N>];
    /**
    Get the absolute value of a [[Number]]
    @param N to absolute
    @param fmt (?=`'s'`) output format
    @param IMap to operate with another set of numbers
    @returns **`string | number | boolean`**
    @example
    ```ts
    import {N} from 'ts-toolbelt'
    
    type test0 = N.Absolute<'-20'>      // '20'
    
    type test1 = N.Absolute<'-20', 's'> // '20'
    type test2 = N.Absolute<'-20', 'n'> //  20
    ```
    */
    export type Absolute<N extends Number, fmt extends Formats = 's', IMap extends Map = NumberMap> = N extends unknown ? Format<_Absolute<IterationOf<N, IMap>, IMap>, fmt> : never;
}
declare module "Number/IsZero" {
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Number } from "Number/Number";
    import { NumberMap } from "Iteration/Maps/Number";
    import { Map } from "Iteration/Map";
    /**
    @hidden
    */
    export type _IsZero<N extends Iteration> = {
        '-': 0;
        '+': 0;
        '0': 1;
    }[N[6]];
    /**
    Check whether a [[Number]] is null or not
    @param N to check
    @param IMap to operate with another set of numbers
    @returns [[Boolean]]
    @example
    ```ts
    import {N} from 'ts-toolbelt'
    
    type test0 = N.IsZero<'0'>  // True
    type test1 = N.IsZero<'-7'> // False
    type test2 = N.IsZero<'7'>  // False
    ```
    */
    export type IsZero<N extends Number, IMap extends Map = NumberMap> = _IsZero<IterationOf<N, IMap>>;
}
declare module "Number/Format" {
    import { Formats } from "Number/_Internal";
    import { Number } from "Number/Number";
    import { IsZero } from "Number/IsZero";
    import { Not } from "Boolean/Not";
    import { Pos } from "Iteration/Pos";
    import { IterationOf } from "Iteration/IterationOf";
    import { NumberMap } from "Iteration/Maps/Number";
    import { Map } from "Iteration/Map";
    /**
    Change the format of a [[Number]]
    @param B to transform
    @param fmt (?=`'s'`) output format
    @param IMap to operate with another set of numbers
    @returns **`string | number | boolean`**
    @example
    ```ts
    import {N} from 'ts-toolbelt'
    
    type test0 = N.Format<'30', 'b'> // True
    type test1 = N.Format<'30', 'n'> // 30
    ```
    */
    export type Format<N extends Number, fmt extends Formats, IMap extends Map = NumberMap> = {
        'b': Not<IsZero<N, IMap>>;
        'n': Pos<IterationOf<N, IMap>>;
        's': N;
    }[fmt];
}
declare module "Number/IsPositive" {
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Number } from "Number/Number";
    import { NumberMap } from "Iteration/Maps/Number";
    import { Map } from "Iteration/Map";
    /**
    @hidden
    */
    export type _IsPositive<N extends Iteration> = {
        '-': 0;
        '+': 1;
        '0': 0;
    }[N[6]];
    /**
    Check whether a [[Number]] is positive or not
    @param N to check
    @returns [[Boolean]]
    @example
    ```ts
    import {N} from 'ts-toolbelt'
    
    type test0 = N.IsPositive<'0'>  // False
    type test1 = N.IsPositive<'-7'> // False
    type test2 = N.IsPositive<'7'>  // True
    ```
    */
    export type IsPositive<N extends Number, IMap extends Map = NumberMap> = _IsPositive<IterationOf<N, IMap>>;
}
declare module "Number/Greater" {
    import { _Minus } from "Number/Minus";
    import { _IsPositive } from "Number/IsPositive";
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Number } from "Number/Number";
    import { NumberMap } from "Iteration/Maps/Number";
    import { Map } from "Iteration/Map";
    /**
    @hidden
    */
    export type _Greater<N1 extends Iteration, N2 extends Iteration, IMap extends Map> = _IsPositive<_Minus<N1, N2, IMap>>;
    /**
    Check if a [[Number]] is bigger than another one
    @param N1 to compare
    @param N2 to compare to
    @param IMap to operate with another set of numbers
    @returns [[Boolean]]
    @example
    ```ts
    import {N} from 'ts-toolbelt'
    
    type test0 = N.Greater<'7', '5'> // True
    type test1 = N.Greater<'5', '5'> // False
    type test2 = N.Greater<'5', '7'> // False
    ```
    */
    export type Greater<N1 extends Number, N2 extends Number, IMap extends Map = NumberMap> = N1 extends unknown ? N2 extends unknown ? _Greater<IterationOf<N1, IMap>, IterationOf<N2, IMap>, IMap> : never : never;
}
declare module "Number/GreaterEq" {
    import { Equals } from "Any/Equals";
    import { _Greater } from "Number/Greater";
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Number } from "Number/Number";
    import { Or } from "Boolean/Or";
    import { NumberMap } from "Iteration/Maps/Number";
    import { Map } from "Iteration/Map";
    /**
    @hidden
    */
    export type _GreaterEq<N1 extends Iteration, N2 extends Iteration, IMap extends Map> = Or<Equals<N1, N2>, _Greater<N1, N2, IMap>>;
    /**
    Check if a [[Number]] is greater or equal to another one
    @param N1 to compare
    @param N2 to compare to
    @param IMap to operate with another set of numbers
    @returns [[Boolean]]
    @example
    ```ts
    import {N} from 'ts-toolbelt'
    
    type test0 = N.GreaterEq<'7', '5'> // True
    type test1 = N.GreaterEq<'5', '5'> // True
    type test2 = N.GreaterEq<'5', '7'> // False
    ```
    */
    export type GreaterEq<N1 extends Number, N2 extends Number, IMap extends Map = NumberMap> = N1 extends unknown ? N2 extends unknown ? _GreaterEq<IterationOf<N1, IMap>, IterationOf<N2, IMap>, IMap> : never : never;
}
declare module "Number/Lower" {
    import { _Greater } from "Number/Greater";
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Number } from "Number/Number";
    import { NumberMap } from "Iteration/Maps/Number";
    import { Map } from "Iteration/Map";
    /**
    @hidden
    */
    export type _Lower<N1 extends Iteration, N2 extends Iteration, IMap extends Map> = _Greater<N2, N1, IMap>;
    /**
    Check if a [[Number]] is lower than another one
    @param N1 to compare
    @param N2 to compare to
    @param IMap to operate with another set of numbers
    @returns [[Boolean]]
    @example
    ```ts
    import {N} from 'ts-toolbelt'
    
    type test0 = N.Lower<'7', '5'> // False
    type test1 = N.Lower<'5', '5'> // False
    type test2 = N.Lower<'5', '7'> // True
    ```
    */
    export type Lower<N1 extends Number, N2 extends Number, IMap extends Map = NumberMap> = N1 extends unknown ? N2 extends unknown ? _Lower<IterationOf<N1, IMap>, IterationOf<N2, IMap>, IMap> : never : never;
}
declare module "Number/LowerEq" {
    import { GreaterEq } from "Number/GreaterEq";
    import { Number } from "Number/Number";
    import { NumberMap } from "Iteration/Maps/Number";
    import { Map } from "Iteration/Map";
    /**
    Check if a [[Number]] is lower or equal to another one
    @param N1 to compare
    @param N2 to compare to
    @param IMap to operate with another set of numbers
    @returns [[Boolean]]
    @example
    ```ts
    import {N} from 'ts-toolbelt'
    
    type test0 = N.LowerEq<'7', '5'> // False
    type test1 = N.LowerEq<'5', '5'> // True
    type test2 = N.LowerEq<'5', '7'> // True
    ```
    */
    export type LowerEq<N1 extends Number, N2 extends Number, IMap extends Map = NumberMap> = GreaterEq<N2, N1, IMap>;
}
declare module "Number/Max" {
    import { IterationOf } from "Iteration/IterationOf";
    import { KnownIterationMapKeys } from "Number/_Internal";
    import { Number } from "Number/Number";
    import { Formats } from "Iteration/_Internal";
    import { Format } from "Iteration/Format";
    import { NumberMap } from "Iteration/Maps/Number";
    import { Map } from "Iteration/Map";
    import { Equals } from "Any/Equals";
    /**
     * @hidden
     */
    type UnionizeCumulatedNumberUnions<N extends Number, IMap extends Map = NumberMap> = {
        [K in keyof IMap[1]]: K extends N ? IMap[1][K][5] : never;
    }[KnownIterationMapKeys<IMap>];
    /**
     * @hidden
     */
    type FindMaxNumberInUnion<N extends Number, IMap extends Map = NumberMap> = UnionizeCumulatedNumberUnions<N, IMap> extends infer Match ? {
        [K in keyof IMap[1]]: Equals<IMap[1][K][5], Match> extends 1 ? K : never;
    }[KnownIterationMapKeys<IMap>] : never;
    /**
    Get the biggest [[Number]] within an [[Union]]
    @param N [[Union]]
    @param fmt (?=`'s'`) output format
    @param IMap to operate with another set of numbers
    @returns **`string | number | boolean`**
    @example
    ```ts
    import {N} from 'ts-toolbelt'
    
    type test0 = N.Max<'-2' | '10' | '3'>      // '10'
    type test1 = N.Max<'-2' | '10' | '3', 's'> // '10'
    type test2 = N.Max<'-2' | '10' | '3', 'n'> //  10
    type test3 = N.Min<'-2' | '10' | 'oops'>   // string
    ```
    */
    export type Max<N extends Number, fmt extends Formats = 's', IMap extends Map = NumberMap> = Format<IterationOf<FindMaxNumberInUnion<N, IMap>, IMap>, fmt>;
}
declare module "Number/Min" {
    import { Number } from "Number/Number";
    import { Formats } from "Iteration/_Internal";
    import { NumberMap } from "Iteration/Maps/Number";
    import { Map } from "Iteration/Map";
    import { Negate } from "Number/Negate";
    import { Max } from "Number/Max";
    /**
    Get the smallest [[Number]] within an [[Union]]
    @param N [[Union]]
    @param fmt (?=`'s'`) output format
    @param IMap to operate with another set of numbers
    @returns **`string | number | boolean`**
    @example
    ```ts
    import {N} from 'ts-toolbelt'
    
    type test0 = N.Min<'-2' | '10' | '3'>      // '-2'
    type test1 = N.Min<'-2' | '10' | '3', 's'> // '-2'
    type test2 = N.Min<'-2' | '10' | '3', 'n'> //  -2
    type test3 = N.Min<'-2' | '10' | 'oops'>   // string
    ```
    */
    export type Min<N extends Number, fmt extends Formats = 's', IMap extends Map = NumberMap> = Negate<Max<Negate<N, 's', IMap>, 's', IMap>, fmt, IMap>;
}
declare module "Number/Plus" {
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Pos } from "Iteration/Pos";
    import { Prev } from "Iteration/Prev";
    import { Next } from "Iteration/Next";
    import { _IsNegative } from "Number/IsNegative";
    import { Cast } from "Any/Cast";
    import { Number } from "Number/Number";
    import { Formats } from "Iteration/_Internal";
    import { Format } from "Iteration/Format";
    import { NumberMap } from "Iteration/Maps/Number";
    import { Map } from "Iteration/Map";
    /**
    @hidden
    */
    type _PlusPositive<N1 extends Iteration, N2 extends Iteration, IMap extends Map> = {
        0: _PlusPositive<Next<N1, IMap>, Prev<N2, IMap>, IMap>;
        1: N1;
        2: number;
    }[Pos<N2> extends 0 ? 1 : number extends Pos<N2> ? 2 : 0];
    /**
    @hidden
    */
    type PlusPositive<N1 extends Iteration, N2 extends Iteration, IMap extends Map> = _PlusPositive<N1, N2, IMap> extends infer X ? Cast<X, Iteration> : never;
    /**
    @hidden
    */
    type _PlusNegative<N1 extends Iteration, N2 extends Iteration, IMap extends Map> = {
        0: _PlusNegative<Prev<N1, IMap>, Next<N2, IMap>, IMap>;
        1: N1;
        2: number;
    }[Pos<N2> extends 0 ? 1 : number extends Pos<N2> ? 2 : 0];
    /**
    @hidden
    */
    type PlusNegative<N1 extends Iteration, N2 extends Iteration, IMap extends Map> = _PlusNegative<N1, N2, IMap> extends infer X ? Cast<X, Iteration> : never;
    /**
    @hidden
    */
    export type _Plus<N1 extends Iteration, N2 extends Iteration, IMap extends Map> = {
        0: PlusPositive<N1, N2, IMap>;
        1: PlusNegative<N1, N2, IMap>;
    }[_IsNegative<N2>];
    /**
    @hidden
    */
    export type __Plus<N1 extends Number, N2 extends Number, fmt extends Formats, IMap extends Map> = Format<_Plus<IterationOf<N1, IMap>, IterationOf<N2, IMap>, IMap>, fmt>;
    /**
    Add a [[Number]] to another one
    @param N1 Left-hand side
    @param N2 Right-hand side
    @param fmt (?=`'s'`) output format
    @param IMap to operate with another set of numbers
    @returns **`string | number | boolean`**
    @example
    ```ts
    import {N} from 'ts-toolbelt'
    
    type test0 = N.Plus<'2', '10'>        // '12'
    type test1 = N.Plus<'0', '40'>        // '40'
    type test2 = N.Plus<'0', '40', 's'>   // '40'
    type test3 = N.Plus<'0', '40', 'n'>   //  40
    type test4 = N.Plus<'-20', '40', 's'> // '20'
    type test5 = N.Plus<'-20', '40', 'n'> //  20
    ```
    */
    export type Plus<N1 extends Number, N2 extends Number, fmt extends Formats = 's', IMap extends Map = NumberMap> = N1 extends unknown ? N2 extends unknown ? __Plus<N1, N2, fmt, IMap> : never : never;
}
declare module "Number/Range" {
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Prepend } from "List/Prepend";
    import { Prev } from "Iteration/Prev";
    import { Next } from "Iteration/Next";
    import { Number } from "Number/Number";
    import { Cast } from "Any/Cast";
    import { Formats } from "Iteration/_Internal";
    import { Way } from "Iteration/_Internal";
    import { Format } from "Iteration/Format";
    import { List } from "List/List";
    import { Extends } from "Any/Extends";
    import { NumberMap } from "Iteration/Maps/Number";
    import { Map } from "Iteration/Map";
    /**
    @hidden
    */
    type RangeForth<From extends Iteration, To extends Iteration, IMap extends Map, fmt extends Formats, L extends List = []> = {
        0: RangeForth<Prev<From, IMap>, To, IMap, fmt, Prepend<L, Format<From, fmt>>>;
        1: L;
    }[Extends<From, To>];
    /**
    @hidden
    */
    type RangeBack<From extends Iteration, To extends Iteration, IMap extends Map, fmt extends Formats, L extends List = []> = {
        0: RangeBack<Next<From, IMap>, To, IMap, fmt, Prepend<L, Format<From, fmt>>>;
        1: L;
    }[Extends<From, To>];
    /**
    @hidden
    */
    type __Range<From extends Iteration, To extends Iteration, way extends Way, fmt extends Formats, IMap extends Map> = {
        '->': RangeForth<To, Prev<From, IMap>, IMap, fmt>;
        '<-': RangeBack<From, Next<To, IMap>, IMap, fmt>;
    }[way];
    /**
    @hidden
    */
    export type _Range<From extends Number, To extends Number, way extends Way, fmt extends Formats, IMap extends Map> = __Range<IterationOf<From, IMap>, IterationOf<To, IMap>, way, fmt, IMap> extends infer X ? Cast<X, (string | number)[]> : never;
    /**
    Create a range of **number**s
    @param From to start with
    @param To to end with
    @param way (?=`'->'`) to reverse it
    @param fmt (?=`'s'`) output format
    @param IMap to operate with another set of numbers
    @returns **`string[] | number[] | boolean[]`**
    @example
    ```ts
    import {N} from 'ts-toolbelt'
    
    type test0 = N.Range<'-2', '1'>            // ['-2', '-1', '0', '1']
    type test1 = N.Range<'-2', '1', '->'>      // ['-2', '-1', '0', '1']
    type test2 = N.Range<'-2', '1', '<-'>      // ['1', '0', '-1', '-2']
    type test3 = N.Range<'-2', '1', '<-', 's'> // ['1', '0', '-1', '-2']
    type test4 = N.Range<'-2', '1', '->', 'n'> // [-2 , -1 ,   0 ,   1 ]
    ```
    */
    export type Range<From extends Number, To extends Number, way extends Way = '->', fmt extends Formats = 's', IMap extends Map = NumberMap> = From extends unknown ? To extends unknown ? _Range<From, To, way, fmt, IMap> : never : never;
}
declare module "Number/_api" {
    /** @ignore */ /** */
    export { Absolute } from "Number/Absolute";
    export { Format } from "Number/Format";
    export { Greater } from "Number/Greater";
    export { GreaterEq } from "Number/GreaterEq";
    export { IsNegative } from "Number/IsNegative";
    export { IsPositive } from "Number/IsPositive";
    export { IsZero } from "Number/IsZero";
    export { Lower } from "Number/Lower";
    export { LowerEq } from "Number/LowerEq";
    export { Max } from "Number/Max";
    export { Min } from "Number/Min";
    export { Minus } from "Number/Minus";
    export { Negate } from "Number/Negate";
    export { NumberOf } from "Number/NumberOf";
    export { Plus } from "Number/Plus";
    export { Range } from "Number/Range";
}
declare module "Object/OptionalKeys" {
    /**
    @hidden
    */
    export type _OptionalKeys<O extends object> = {
        [K in keyof O]-?: {} extends Pick<O, K> ? K : never;
    }[keyof O];
    /**
    Get the keys of **`O`** that are optional
    @param O
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type OptionalKeys<O extends object> = O extends unknown ? _OptionalKeys<O> : never;
}
declare module "Object/Merge" {
    import { AtBasic } from "Object/At";
    import { _OptionalKeys } from "Object/OptionalKeys";
    import { Key } from "Any/Key";
    import { _ListOf } from "Object/ListOf";
    import { List } from "List/List";
    import { Depth, Anyfy, MergeStyle } from "Object/_Internal";
    import { NonNullable } from "Union/NonNullable";
    import { BuiltInObject } from "Misc/BuiltInObject";
    import { ObjectOf } from "List/ObjectOf";
    /**
    @hidden
    */
    type LibStyle<Merged, O, O1, style extends MergeStyle> = {
        0: [O] extends [List] ? [O1] extends [List] ? _ListOf<Merged & {}> : O : Merged;
        1: Merged;
        2: [O] extends [List] ? [O1] extends [List] ? Merged[keyof Merged][] : O : Merged;
    }[style];
    /**
    @hidden
    */
    type MergeProp<OK, O1K, K extends Key, OOK extends Key, style extends MergeStyle> = K extends OOK ? NonNullable<OK> | O1K : [OK] extends [never] ? O1K : {
        0: OK extends undefined ? O1K : OK;
        1: OK;
        2: OK extends undefined ? O1K : OK;
    }[style];
    /**
    @hidden
    */
    type __MergeFlat<O extends object, O1 extends object, style extends MergeStyle, OOK extends Key = _OptionalKeys<O>> = {
        [K in keyof (Anyfy<O> & O1)]: MergeProp<AtBasic<O, K>, AtBasic<O1, K>, K, OOK, style>;
    } & {};
    /**
    @hidden
    */
    export type _MergeFlat<O extends object, O1 extends object, style extends MergeStyle> = LibStyle<__MergeFlat<ObjectOf<O>, ObjectOf<O1>, style>, O, O1, style>;
    /**
    @hidden
    */
    export type MergeFlat<O extends object, O1 extends object, style extends MergeStyle, noMerge> = O extends noMerge ? O : O1 extends noMerge ? O : _MergeFlat<O, O1, style>;
    /**
    @hidden
    */
    type __MergeDeep<O extends object, O1 extends object, style extends MergeStyle, noMerge, OOK extends Key = _OptionalKeys<O>> = {
        [K in keyof (Anyfy<O> & O1)]: _MergeDeep<AtBasic<O, K>, AtBasic<O1, K>, K, OOK, style, noMerge>;
    };
    /**
    @hidden
    */
    type ChooseMergeDeep<OK, O1K, K extends Key, OOK extends Key, style extends MergeStyle, noMerge> = OK extends noMerge ? MergeProp<OK, O1K, K, OOK, style> : O1K extends noMerge ? MergeProp<OK, O1K, K, OOK, style> : OK extends object ? O1K extends object ? __MergeDeep<ObjectOf<OK>, ObjectOf<O1K>, style, noMerge> : MergeProp<OK, O1K, K, OOK, style> : MergeProp<OK, O1K, K, OOK, style>;
    /**
    @hidden
    */
    export type _MergeDeep<O, O1, K extends Key, OOK extends Key, style extends MergeStyle, noMerge> = [
        O
    ] extends [never] ? MergeProp<O, O1, K, OOK, style> : [O1] extends [never] ? MergeProp<O, O1, K, OOK, style> : LibStyle<ChooseMergeDeep<O, O1, K, OOK, style, noMerge>, O, O1, style>;
    /**
    @hidden
    */
    export type MergeDeep<O, O1, style extends MergeStyle, noMerge> = O extends unknown ? O1 extends unknown ? _MergeDeep<O, O1, 'x', 'y', style, noMerge> : never : never;
    /**
    Accurately merge the fields of **`O`** with the ones of **`O1`**. It is
    equivalent to the spread operator in JavaScript. [[Union]]s and [[Optional]]
    fields will be handled gracefully.
    
    (⚠️ needs `--strictNullChecks` enabled)
    @param O to complete
    @param O1 to copy from
    @param depth (?=`'flat'`) to do it deeply
    @param style (?=`1`) 0 = lodash, 1 = ramda
    @param noMerge (?=`BuiltinObject`) types not to merge
    @returns [[Object]]
    @example
    ```ts
    import {O} from 'ts-toolbelt'
    
    type O = {
        name?: string
        age? : number
        zip? : string
        pay  : {
            cvv?: number
        }
    }
    
    type O1 = {
        age : number
        zip?: number
        city: string
        pay : {
            cvv : number
            ccn?: string
        }
    }
    
    type test = O.Merge<O, O1, 'deep'>
    // {
    //     name?: string;
    //     age: number;
    //     zip?: string | number;
    //     pay: {
    //         cvv: number;
    //         ccn?: string;
    //     };
    //     city: string;
    // }
    ```
    */
    export type Merge<O extends object, O1 extends object, depth extends Depth = 'flat', style extends MergeStyle = 2, noMerge = BuiltInObject> = {
        'flat': MergeFlat<O, O1, style, noMerge>;
        'deep': MergeDeep<O, O1, style, noMerge>;
    }[depth];
}
declare module "Object/P/Merge" {
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Pos } from "Iteration/Pos";
    import { Next } from "Iteration/Next";
    import { Key } from "Any/Key";
    import { Merge as OMerge } from "Object/Merge";
    import { Length } from "List/Length";
    import { List } from "List/List";
    import { Depth } from "Object/_Internal";
    import { Boolean } from "Boolean/Boolean";
    /**
    @hidden
    */
    type MergeObject<O, Path extends List<Key>, O1 extends object, depth extends Depth, I extends Iteration = IterationOf<'0'>> = O extends object ? Pos<I> extends Length<Path> ? OMerge<O, O1, depth> : {
        [K in keyof O]: K extends Path[Pos<I>] ? MergeObject<O[K], Path, O1, depth, Next<I>> : O[K];
    } & {} : O;
    /**
    @hidden
    */
    type MergeList<O, Path extends List<Key>, O1 extends object, depth extends Depth, I extends Iteration = IterationOf<'0'>> = O extends object ? O extends (infer A)[] ? MergeList<A, Path, O1, depth, I>[] : Pos<I> extends Length<Path> ? OMerge<O, O1, depth> : {
        [K in keyof O]: K extends Path[Pos<I>] ? MergeList<O[K], Path, O1, depth, Next<I>> : O[K];
    } & {} : O;
    /**
    Complete the fields of **`O`** at **`Path`** with the ones of **`O1`**
    @param O to complete
    @param Path to be followed
    @param O1 to copy from
    @param depth (?=`'flat'`) to do it deeply
    @param list (?=`0`) `1` to work within object lists
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Merge<O extends object, Path extends List<Key>, O1 extends object, depth extends Depth = 'flat', list extends Boolean = 0> = {
        0: MergeObject<O, Path, O1, depth>;
        1: MergeList<O, Path, O1, depth>;
    }[list];
}
declare module "List/LastIndex" {
    import { Length } from "List/Length";
    import { Formats } from "Iteration/_Internal";
    import { Tail } from "List/Tail";
    import { List } from "List/List";
    /**
    Get the last index of **`L`**
    @param L to get from
    @param fmt (?=`'n'`) output format
    @returns [[String]] or **`number`**
    @example
    ```ts
    ```
    */
    export type LastIndex<L extends List, fmt extends Formats = 'n'> = Length<Tail<L>, fmt>;
}
declare module "Object/P/Omit" {
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Pos } from "Iteration/Pos";
    import { Next } from "Iteration/Next";
    import { Key } from "Any/Key";
    import { _Omit as _OOmit } from "Object/Omit";
    import { LastIndex } from "List/LastIndex";
    import { List } from "List/List";
    import { Boolean } from "Boolean/Boolean";
    /**
    @hidden
    */
    type OmitObject<O, Path extends List<Key>, I extends Iteration = IterationOf<'0'>> = O extends object ? Pos<I> extends LastIndex<Path> ? _OOmit<O, Path[Pos<I>]> : {
        [K in keyof O]: K extends Path[Pos<I>] ? OmitObject<O[K], Path, Next<I>> : O[K];
    } & {} : O;
    /**
    @hidden
    */
    type OmitList<O, Path extends List<Key>, I extends Iteration = IterationOf<'0'>> = O extends object ? O extends (infer A)[] ? OmitList<A, Path, I>[] : Pos<I> extends LastIndex<Path> ? _OOmit<O, Path[Pos<I>]> : {
        [K in keyof O]: K extends Path[Pos<I>] ? OmitList<O[K], Path, Next<I>> : O[K];
    } & {} : O;
    /**
    Remove out of **`O`** the fields at **`Path`**
    @param O to remove from
    @param Path to be followed
    @param list (?=`0`) `1` to work within object lists
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Omit<O extends object, Path extends List<Key>, list extends Boolean = 0> = {
        0: OmitObject<O, Path>;
        1: OmitList<O, Path>;
    }[list];
}
declare module "Object/P/Pick" {
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Pos } from "Iteration/Pos";
    import { Next } from "Iteration/Next";
    import { Key } from "Any/Key";
    import { _Pick as _OPick } from "Object/Pick";
    import { LastIndex } from "List/LastIndex";
    import { List } from "List/List";
    import { Boolean } from "Boolean/Boolean";
    /**
    @hidden
    */
    type PickObject<O, Path extends List<Key>, I extends Iteration = IterationOf<'0'>> = O extends object ? _OPick<O, Path[Pos<I>]> extends infer Picked ? Pos<I> extends LastIndex<Path> ? Picked : {
        [K in keyof Picked]: PickObject<Picked[K], Path, Next<I>>;
    } & {} : never : O;
    /**
    @hidden
    */
    type PickList<O, Path extends List<Key>, I extends Iteration = IterationOf<'0'>> = O extends object ? O extends (infer A)[] ? PickList<A, Path, I>[] : _OPick<O, Path[Pos<I>]> extends infer Picked ? Pos<I> extends LastIndex<Path> ? Picked : {
        [K in keyof Picked]: PickList<Picked[K], Path, Next<I>>;
    } & {} : never : O;
    /**
    Extract out of **`O`** the fields at **`Path`**
    @param O to extract from
    @param Path to be followed
    @param list (?=`0`) `1` to work within object lists
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Pick<O extends object, Path extends List<Key>, list extends Boolean = 0> = {
        0: PickObject<O, Path>;
        1: PickList<O, Path>;
    }[list];
}
declare module "Object/Readonly" {
    import { _Pick } from "Object/Pick";
    import { Depth } from "Object/_Internal";
    import { Key } from "Any/Key";
    import { _PatchFlat } from "Object/Patch";
    import { BuiltInObject } from "Misc/BuiltInObject";
    /**
    @hidden
    */
    export type ReadonlyFlat<O> = {
        +readonly [K in keyof O]: O[K];
    } & {};
    /**
    @hidden
    */
    export type ReadonlyDeep<O> = {
        +readonly [K in keyof O]: O[K] extends BuiltInObject ? O[K] : ReadonlyDeep<O[K]>;
    };
    /**
    @hidden
    */
    export type ReadonlyPart<O extends object, depth extends Depth> = {
        'flat': ReadonlyFlat<O>;
        'deep': ReadonlyDeep<O>;
    }[depth];
    /**
     * @hidden
     */
    export type _Readonly<O extends object, K extends Key, depth extends Depth> = _PatchFlat<ReadonlyPart<_Pick<O, K>, depth>, O, 2>;
    /**
    Make some fields of **`O`** readonly (deeply or not)
    @param O to make readonly
    @param K (?=`Key`) to choose fields
    @param depth (?=`'default'`) to do it deeply
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Readonly<O extends object, K extends Key = Key, depth extends Depth = 'flat'> = O extends unknown ? _Readonly<O, K, depth> : never;
}
declare module "Object/P/Readonly" {
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Pos } from "Iteration/Pos";
    import { Next } from "Iteration/Next";
    import { Key } from "Any/Key";
    import { Readonly as OReadonly } from "Object/Readonly";
    import { LastIndex } from "List/LastIndex";
    import { List } from "List/List";
    import { Depth } from "Object/_Internal";
    import { Boolean } from "Boolean/Boolean";
    /**
    @hidden
    */
    type ReadonlyObject<O, Path extends List<Key>, depth extends Depth, I extends Iteration = IterationOf<'0'>> = O extends object ? Pos<I> extends LastIndex<Path> ? OReadonly<O, Path[Pos<I>], depth> : {
        [K in keyof O]: K extends Path[Pos<I>] ? ReadonlyObject<O[K], Path, depth, Next<I>> : O[K];
    } & {} : O;
    /**
    @hidden
    */
    type ReadonlyArrays<O, Path extends List<Key>, depth extends Depth, I extends Iteration = IterationOf<'0'>> = O extends object ? O extends (infer A)[] ? ReadonlyArrays<A, Path, depth, I>[] : Pos<I> extends LastIndex<Path> ? OReadonly<O, Path[Pos<I>], depth> : {
        [K in keyof O]: K extends Path[Pos<I>] ? ReadonlyArrays<O[K], Path, depth, Next<I>> : O[K];
    } & {} : O;
    /**
    Make some fields of **`O`** readonly at **`Path`** (deeply or not)
    @param O to make readonly
    @param Path to be followed
    @param depth (?=`'flat'`) to do it deeply
    @param list (?=`0`) `1` to work within object lists
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Readonly<O extends object, Path extends List<Key>, depth extends Depth = 'flat', list extends Boolean = 0> = {
        0: ReadonlyObject<O, Path, depth>;
        1: ReadonlyArrays<O, Path, depth>;
    }[list];
}
declare module "Object/Record" {
    import { Modx } from "Object/_Internal";
    import { Key } from "Any/Key";
    /**
    Create an object filled with **`A`** for the fields **`K`**
    @param K to choose fields
    @param A to fill fields with
    @param modx (?=`['!', 'W']`) to set modifiers
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Record<K extends Key, A extends any, modx extends Modx = ['!', 'W']> = {
        '!': {
            'R': {
                readonly [P in K]: A;
            };
            'W': {
                [P in K]: A;
            };
        };
        '?': {
            'R': {
                readonly [P in K]?: A;
            };
            'W': {
                [P in K]?: A;
            };
        };
    }[modx[0]][modx[1]];
}
declare module "Object/P/Update" {
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Pos } from "Iteration/Pos";
    import { Next } from "Iteration/Next";
    import { Key } from "Any/Key";
    import { LastIndex } from "List/LastIndex";
    import { List } from "List/List";
    import { Record } from "Object/Record";
    import { Patch } from "Object/Patch";
    /**
    @hidden
    */
    type _Update<O, Path extends List<Key>, A, I extends Iteration = IterationOf<'0'>> = O extends object ? Pos<I> extends LastIndex<Path> ? Patch<Record<Path[Pos<I>], A>, O> : (O & Record<Exclude<Path[Pos<I>], keyof O>, {}>) extends infer O ? {
        [K in keyof O]: K extends Path[Pos<I>] ? _Update<O[K], Path, A, Next<I>> : O[K];
    } & {} : never : O;
    /**
    Update in **`O`** the fields at **`Path`** with **`A`**
    @param O to update
    @param Path to be followed
    @param A to update with
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Update<O extends object, Path extends List<Key>, A extends any> = _Update<O, Path, A>;
}
declare module "Object/P/Record" {
    import { Modx } from "Object/_Internal";
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Pos } from "Iteration/Pos";
    import { Next } from "Iteration/Next";
    import { Key } from "Any/Key";
    import { LastIndex } from "List/LastIndex";
    import { List } from "List/List";
    /**
    @hidden
    */
    type _Record_RR<Path extends List<Key>, A, I extends Iteration = IterationOf<'0'>> = {
        readonly [Key in Path[Pos<I>]]: Pos<I> extends LastIndex<Path> ? A : _Record_RR<Path, A, Next<I>>;
    } & {};
    /**
    @hidden
    */
    export type _Record_RW<Path extends List<Key>, A, I extends Iteration = IterationOf<'0'>> = {
        [Key in Path[Pos<I>]]: Pos<I> extends LastIndex<Path> ? A : _Record_RW<Path, A, Next<I>>;
    } & {};
    /**
    @hidden
    */
    type _Record_OR<Path extends List<Key>, A, I extends Iteration = IterationOf<'0'>> = {
        readonly [Key in Path[Pos<I>]]?: Pos<I> extends LastIndex<Path> ? A : _Record_OR<Path, A, Next<I>>;
    } & {};
    /**
    @hidden
    */
    type _Record_OW<Path extends List<Key>, A, I extends Iteration = IterationOf<'0'>> = {
        [Key in Path[Pos<I>]]?: Pos<I> extends LastIndex<Path> ? A : _Record_OW<Path, A, Next<I>>;
    } & {};
    /**
    Create an object filled with **`A`** for the fields at the end of **`Path`**
    @param Path to choose fields
    @param A to fill fields with
    @param modx (?=`['!', 'W']`) to set modifiers
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Record<Path extends List<Key>, A, modx extends Modx = ['!', 'W']> = {
        '!': {
            'R': _Record_RR<Path, A>;
            'W': _Record_RW<Path, A>;
        };
        '?': {
            'R': _Record_OR<Path, A>;
            'W': _Record_OW<Path, A>;
        };
    }[modx[0]][modx[1]];
}
declare module "Object/P/_api" {
    /** @ignore */ /** */
    export { Merge } from "Object/P/Merge";
    export { Omit } from "Object/P/Omit";
    export { Pick } from "Object/P/Pick";
    export { Readonly } from "Object/P/Readonly";
    export { Update } from "Object/P/Update";
    export { Record } from "Object/P/Record";
}
declare module "Object/Assign" {
    import { Iteration } from "Iteration/Iteration";
    import { IterationOf } from "Iteration/IterationOf";
    import { Merge } from "Object/Merge";
    import { Pos } from "Iteration/Pos";
    import { Next } from "Iteration/Next";
    import { Length } from "List/Length";
    import { Cast } from "Any/Cast";
    import { List } from "List/List";
    import { Extends } from "Any/Extends";
    import { Depth, MergeStyle } from "Object/_Internal";
    import { BuiltInObject } from "Misc/BuiltInObject";
    /**
    @hidden
    */
    type __Assign<O extends object, Os extends List<object>, depth extends Depth, style extends MergeStyle, noMerge extends any, I extends Iteration = IterationOf<'0'>> = {
        0: __Assign<Merge<Os[Pos<I>], O, depth, style, noMerge>, Os, depth, style, noMerge, Next<I>>;
        1: O;
    }[Extends<Pos<I>, Length<Os>>];
    /**
    @hidden
    */
    export type _Assign<O extends object, Os extends List<object>, depth extends Depth, style extends MergeStyle, noMerge extends any> = __Assign<O, Os, depth, style, noMerge> extends infer X ? Cast<X, object> : never;
    /**
    Assign a list of [[Object]] into **`O`** with [[Merge]]. Merges from right to
    left, first items get overridden by the next ones (last-in overrides).
    @param O to assign to
    @param Os to assign
    @param depth (?=`'flat'`) to do it deeply
    @param style (?=`1`) 0 = lodash, 1 = ramda
    @param noMerge (?=`BuiltinObject`) types not to merge
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Assign<O extends object, Os extends List<object>, depth extends Depth = 'flat', style extends MergeStyle = 2, noMerge extends any = BuiltInObject> = O extends unknown ? Os extends unknown ? _Assign<O, Os, depth, style, noMerge> : never : never;
}
declare module "Union/Keys" {
    import { Union } from "Union/Union";
    /**
    Get the keys of a [[Union]]
    @param U
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type Keys<U extends Union> = U extends unknown ? keyof U : never;
}
declare module "Object/Keys" {
    import { Keys as UKeys } from "Union/Keys";
    /**
    Get the keys of an [[Object]]
    @param O
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type Keys<O extends object> = UKeys<O>;
}
declare module "Object/Required" {
    import { _Pick } from "Object/Pick";
    import { Depth } from "Object/_Internal";
    import { Key } from "Any/Key";
    import { _PatchFlat } from "Object/Patch";
    import { BuiltInObject } from "Misc/BuiltInObject";
    /**
    @hidden
    */
    export type RequiredFlat<O> = {
        [K in keyof O]-?: O[K];
    } & {};
    /**
    @hidden
    */
    export type RequiredDeep<O> = {
        [K in keyof O]-?: O[K] extends BuiltInObject ? O[K] : RequiredDeep<O[K]>;
    };
    /**
    @hidden
    */
    export type RequiredPart<O extends object, depth extends Depth> = {
        'flat': RequiredFlat<O>;
        'deep': RequiredDeep<O>;
    }[depth];
    /**
     * @hidden
     */
    export type _Required<O extends object, K extends Key, depth extends Depth> = _PatchFlat<RequiredPart<_Pick<O, K>, depth>, O, 2>;
    /**
    Make some fields of **`O`** required (deeply or not)
    @param O to make required
    @param K (?=`Key`) to choose fields
    @param depth (?=`'flat'`) to do it deeply
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Required<O extends object, K extends Key = Key, depth extends Depth = 'flat'> = O extends unknown ? _Required<O, K, depth> : never;
}
declare module "Object/Optional" {
    import { _Pick } from "Object/Pick";
    import { Depth } from "Object/_Internal";
    import { Key } from "Any/Key";
    import { _PatchFlat } from "Object/Patch";
    import { BuiltInObject } from "Misc/BuiltInObject";
    /**
    @hidden
    */
    export type OptionalFlat<O> = {
        [K in keyof O]?: O[K];
    } & {};
    /**
    @hidden
    */
    export type OptionalDeep<O> = {
        [K in keyof O]?: O[K] extends BuiltInObject ? O[K] : OptionalDeep<O[K]>;
    };
    /**
    @hidden
    */
    export type OptionalPart<O extends object, depth extends Depth> = {
        'flat': OptionalFlat<O>;
        'deep': OptionalDeep<O>;
    }[depth];
    /**
     * @hidden
     */
    export type _Optional<O extends object, K extends Key, depth extends Depth> = _PatchFlat<OptionalPart<_Pick<O, K>, depth>, O, 2>;
    /**
    Make some fields of **`O`** optional (deeply or not)
    @param O to make optional
    @param K (?=`Key`) to choose fields
    @param depth (?=`'flat'`) to do it deeply
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Optional<O extends object, K extends Key = Key, depth extends Depth = 'flat'> = O extends unknown ? _Optional<O, K, depth> : never;
}
declare module "Object/AtLeast" {
    import { _Pick } from "Object/Pick";
    import { Key } from "Any/Key";
    import { Keys } from "Object/Keys";
    import { RequiredFlat } from "Object/Required";
    import { Extends } from "Any/Extends";
    import { ComputeRaw } from "Any/Compute";
    import { OptionalFlat } from "Object/Optional";
    /**
    @hidden
    */
    type RequiredIfKeys<O extends object, K extends Key> = Extends<keyof O & K, K> extends 1 ? RequiredFlat<O> : O;
    /**
    @hidden
    */
    type __AtLeast<O extends object, K extends Key> = K extends keyof O ? _Pick<O, K> & OptionalFlat<O> : O;
    /**
    @hidden
    */
    type _AtLeast<O extends object, K extends Key> = ComputeRaw<__AtLeast<RequiredIfKeys<O, K>, K>>;
    /**
    Make that at least one of the keys **`K`** are required in **`O`** at a time.
    @param O to make required
    @param K (?=`keyof O`) to choose fields
    @returns [[Object]] [[Union]]
    @example
    ```ts
    ```
    */
    export type AtLeast<O extends object, K extends Key = Keys<O>> = O extends unknown ? _AtLeast<O, K> : never;
}
declare module "Object/Compulsory" {
    import { _Pick } from "Object/Pick";
    import { Depth } from "Object/_Internal";
    import { Key } from "Any/Key";
    import { NonNullable } from "Union/NonNullable";
    import { _PatchFlat } from "Object/Patch";
    import { BuiltInObject } from "Misc/BuiltInObject";
    /**
    @hidden
    */
    export type CompulsoryFlat<O> = {
        [K in keyof O]-?: NonNullable<O[K]>;
    } & {};
    /**
    @hidden
    */
    export type CompulsoryDeep<O> = {
        [K in keyof O]-?: O[K] extends BuiltInObject ? O[K] : CompulsoryDeep<NonNullable<O[K]>>;
    };
    /**
    @hidden
    */
    export type CompulsoryPart<O extends object, depth extends Depth> = {
        'flat': CompulsoryFlat<O>;
        'deep': CompulsoryDeep<O>;
    }[depth];
    /**
     * @hidden
     */
    export type _Compulsory<O extends object, K extends Key, depth extends Depth> = _PatchFlat<CompulsoryPart<_Pick<O, K>, depth>, O, 2>;
    /**
    Make that **`O`**'s fields cannot be [[Nullable]] or [[Optional]] (it's like
    [[Required]] & [[NonNullable]] at once).
    @param O to make compulsory
    @param K (?=`Key`) to choose fields
    @param depth (?=`'flat'`) to do it deeply
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Compulsory<O extends object, K extends Key = Key, depth extends Depth = 'flat'> = O extends unknown ? _Compulsory<O, K, depth> : never;
}
declare module "Object/CompulsoryKeys" {
    /**
    @hidden
    */
    export type _CompulsoryKeys<O extends object> = {
        [K in keyof O]-?: [O[K] & (undefined | null)] extends [never] ? K : never;
    }[keyof O];
    /**
    Get the keys of **`O`** that are [[Compulsory]]
    
    (⚠️ needs `--strictNullChecks` enabled)
    @param O
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type CompulsoryKeys<O extends object> = O extends unknown ? _CompulsoryKeys<O> : never;
}
declare module "Object/ExcludeKeys" {
    import { Exclude } from "Union/Exclude";
    import { Match } from "Any/_Internal";
    import { Is } from "Any/Is";
    import { At } from "Object/At";
    import { Keys } from "Object/Keys";
    /**
    @hidden
    */
    export type _ExcludeMatch<O extends object, O1 extends object, match extends Match> = {
        [K in keyof O]-?: {
            1: never;
            0: K;
        }[Is<O[K], At<O1, K>, match>];
    }[keyof O];
    /**
    @hidden
    */
    type ExcludeMatch<O extends object, O1 extends object, match extends Match> = O extends unknown ? _ExcludeMatch<O, O1, match> : never;
    /**
    Exclude the keys of **`O1`** out of the keys of **`O`**
    (If `match = 'default'`, no type checks are done)
    @param O to remove the keys from
    @param O1 to remove the keys out
    @param match (?=`'default'`) to change precision
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type ExcludeKeys<O extends object, O1 extends object, match extends Match = 'default'> = {
        'default': Exclude<Keys<O>, Keys<O1>>;
        'contains->': ExcludeMatch<O, O1, 'contains->'>;
        'extends->': ExcludeMatch<O, O1, 'extends->'>;
        'implements->': ExcludeMatch<O, O1, 'implements->'>;
        '<-contains': ExcludeMatch<O, O1, '<-contains'>;
        '<-extends': ExcludeMatch<O, O1, '<-extends'>;
        '<-implements': ExcludeMatch<O, O1, '<-implements'>;
        'equals': ExcludeMatch<O, O1, 'equals'>;
    }[match];
}
declare module "Object/Exclude" {
    import { ExcludeKeys } from "Object/ExcludeKeys";
    import { Match } from "Any/_Internal";
    import { Pick } from "Object/Pick";
    /**
    Exclude the fields of **`O1`** out of **`O`**
    (If `match = 'default'`, no type checks are done)
    @param O to remove from
    @param O1 to remove out
    @param match (?=`'default'`) to change precision
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Exclude<O extends object, O1 extends object, match extends Match = 'default'> = Pick<O, ExcludeKeys<O, O1, match>>;
}
declare module "Object/Diff" {
    import { Exclude } from "Object/Exclude";
    import { Match } from "Any/_Internal";
    import { PatchFlat } from "Object/Patch";
    /**
    Get an [[Object]] that is the difference between **`O`** & **`O1`**
    (**`O`**'s differences have priority over **`O1`**'s if fields overlap)
    (If `match = 'default'`, no type checks are done)
    @param O to check differences with
    @param O1 to check differences against
    @param match (?=`'default'`) to change precision
    @returns [[Object]]
    @example
    ```ts
    import {O} from 'ts-toolbelt'
    
    type Person0 = {
        name: string
        age: string
    }
    
    type Person1 = {
        name: string
        age: number | string
        nick: string
    }
    
    type test0 = O.Diff<Person0, Person1, 'default'>   // {nick: string}
    type test1 = O.Diff<Person0, Person1, 'extends->'> // {nick: string; age: string | number}
    type test2 = O.Diff<Person0, Person1, '<-extends'> // {nick: string; age: string}
    type test3 = O.Diff<Person0, Person1, 'equals'>    // {nick: string; age: string}
    ```
    */
    export type Diff<O extends object, O1 extends object, match extends Match = 'default'> = PatchFlat<Exclude<O, O1, match>, Exclude<O1, O, match>>;
}
declare module "Union/Strict" {
    import { ComputeRaw } from "Any/Compute";
    import { Keys } from "Union/Keys";
    import { OptionalFlat } from "Object/Optional";
    import { Record } from "Object/Record";
    /**
    @hidden
    */
    type _Strict<U, _U = U> = U extends unknown ? U & OptionalFlat<Record<Exclude<Keys<_U>, keyof U>, never>> : never;
    /**
    Make a [[Union]] not allow excess properties (https://github.com/Microsoft/TypeScript/issues/20863)
    @param U to make strict
    @returns [[Union]]
    @example
    ```ts
    ```
    */
    export type Strict<U extends object> = ComputeRaw<_Strict<U>>;
}
declare module "Object/Either" {
    import { _Omit } from "Object/Omit";
    import { _Pick } from "Object/Pick";
    import { Key } from "Any/Key";
    import { Strict } from "Union/Strict";
    import { Boolean } from "Boolean/Boolean";
    import { ComputeRaw } from "Any/Compute";
    /**
    @hidden
    */
    type __Either<O extends object, K extends Key> = _Omit<O, K> & ({
        [P in K]: _Pick<O, P>;
    }[K]);
    /**
    @hidden
    */
    type EitherStrict<O extends object, K extends Key> = Strict<__Either<O, K>>;
    /**
    @hidden
    */
    type EitherLoose<O extends object, K extends Key> = ComputeRaw<__Either<O, K>>;
    /**
    @hidden
    */
    export type _Either<O extends object, K extends Key, strict extends Boolean> = {
        1: EitherStrict<O, K>;
        0: EitherLoose<O, K>;
    }[strict];
    /**
    Split **`O`** into a [[Union]] with **`K`** keys in such a way that none of
    the keys are ever present with one another within the different unions.
    @param O to split
    @param K to split with
    @param strict (?=`1`) to force excess property checks https://github.com/microsoft/TypeScript/issues/20863
    @returns [[Object]] [[Union]]
    @example
    ```ts
    ```
    */
    export type Either<O extends object, K extends Key, strict extends Boolean = 1> = O extends unknown ? _Either<O, K, strict> : never;
}
declare module "Object/FilterKeys" {
    import { Match } from "Any/_Internal";
    import { Is } from "Any/Is";
    /**
    @hidden
    */
    export type _FilterKeys<O extends object, M extends any, match extends Match> = {
        [K in keyof O]-?: {
            1: never;
            0: K;
        }[Is<O[K], M, match>];
    }[keyof O];
    /**
    Filter out the keys of **`O`** which fields match **`M`**
    @param O to remove from
    @param M to select fields
    @param match (?=`'default'`) to change precision
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type FilterKeys<O extends object, M extends any, match extends Match = 'default'> = O extends unknown ? _FilterKeys<O, M, match> : never;
}
declare module "Object/Filter" {
    import { FilterKeys } from "Object/FilterKeys";
    import { Match } from "Any/_Internal";
    import { Pick } from "Object/Pick";
    /**
    Filter out of **`O`** the fields that match **`M`**
    @param O to remove from
    @param M to select fields
    @param match (?=`'default'`) to change precision
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Filter<O extends object, M extends any, match extends Match = 'default'> = Pick<O, FilterKeys<O, M, match>>;
}
declare module "Object/Has" {
    import { Match } from "Any/_Internal";
    import { Is } from "Any/Is";
    import { At } from "Object/At";
    import { Key } from "Any/Key";
    /**
    Check whether **`O`** has a field of key **`K`** that matches **`M`**
    @param O to be inspected
    @param K to choose field
    @param M (?=`any`) to check field type
    @param match (?=`'default'`) to change precision
    @returns [[Boolean]]
    @example
    ```ts
    ```
    */
    export type Has<O extends object, K extends Key, M extends any = any, match extends Match = 'default'> = Is<At<O, K>, M, match>;
}
declare module "Object/Path" {
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Next } from "Iteration/Next";
    import { Pos } from "Iteration/Pos";
    import { Length } from "List/Length";
    import { At } from "Object/At";
    import { Cast } from "Any/Cast";
    import { NonNullable } from "Union/NonNullable";
    import { Key } from "Any/Key";
    import { List } from "List/List";
    import { Boolean } from "Boolean/Boolean";
    import { Extends } from "Any/Extends";
    /**
    @hidden
    */
    type __Path<O, Path extends List<Key>, strict extends Boolean, I extends Iteration = IterationOf<'0'>> = {
        0: __Path<At<NonNullable<O> & {}, Path[Pos<I>], strict>, Path, strict, Next<I>>;
        1: O;
    }[Extends<Pos<I>, Length<Path>>];
    /**
    @hidden
    */
    export type _Path<O extends object, Path extends List<Key>, strict extends Boolean> = __Path<O, Path, strict> extends infer X ? Cast<X, any> : never;
    /**
    Get in **`O`** the type of nested properties
    @param O to be inspected
    @param Path to be followed
    @param strict (?=`1`) `0` to work with unions
    @returns **`any`**
    @example
    ```ts
    ```
    */
    export type Path<O extends object, Path extends List<Key>, strict extends Boolean = 1> = Path extends unknown ? _Path<O, Path, strict> : never;
}
declare module "Object/HasPath" {
    import { Match } from "Any/_Internal";
    import { Path as OPath } from "Object/Path";
    import { Is } from "Any/Is";
    import { Key } from "Any/Key";
    import { List } from "List/List";
    /**
    Check whether **`O`** has nested properties that match **`M`**
    @param O to be inspected
    @param Path to be followed
    @param M (?=`any`) to check field type
    @param match (?=`'default'`) to change precision
    @returns [[Boolean]]
    @example
    ```ts
    ```
    */
    export type HasPath<O extends object, Path extends List<Key>, M extends any = any, match extends Match = 'default'> = Is<OPath<O, Path>, M, match>;
}
declare module "Object/SelectKeys" {
    import { Match } from "Any/_Internal";
    import { Is } from "Any/Is";
    /**
    @hidden
    */
    export type _SelectKeys<O extends object, M extends any, match extends Match> = {
        [K in keyof O]-?: {
            1: K;
            0: never;
        }[Is<O[K], M, match>];
    }[keyof O];
    /**
    Get the keys of **`O`** which fields match **`M`**
    @param O to extract from
    @param M to select fields
    @param match (?=`'default'`) to change precision
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type SelectKeys<O extends object, M extends any, match extends Match = 'default'> = O extends unknown ? _SelectKeys<O, M, match> : never;
}
declare module "Object/Includes" {
    import { SelectKeys } from "Object/SelectKeys";
    import { Match } from "Any/_Internal";
    /**
    Check whether **`O`** has fields that match **`M`**
    @param O to be inspected
    @param M to check field type
    @param match (?=`'default'`) to change precision
    @returns [[Boolean]]
    @example
    ```ts
    ```
    */
    export type Includes<O extends object, M extends any, match extends Match = 'default'> = [
        SelectKeys<O, M, match>
    ] extends [never] ? 0 : 1;
}
declare module "Union/Intersect" {
    import { Union } from "Union/Union";
    /**
    Get the intersection of **`U1`** & **`U2`**
    @param U1 to check similarities with
    @param U2 to check similarities against
    @returns [[Union]]
    @example
    ```ts
    ```
    */
    export type Intersect<U1 extends Union, U2 extends Union> = U1 & U2;
}
declare module "Object/IntersectKeys" {
    import { Intersect } from "Union/Intersect";
    import { Match } from "Any/_Internal";
    import { Is } from "Any/Is";
    import { At } from "Object/At";
    import { Keys } from "Object/Keys";
    /**
    @hidden
    */
    export type _IntersectMatch<O extends object, O1 extends object, match extends Match> = {
        [K in keyof O]-?: {
            1: K;
            0: never;
        }[Is<O[K], At<O1, K>, match>];
    }[keyof O];
    /**
    @hidden
    */
    type IntersectMatch<O extends object, O1 extends object, match extends Match> = O extends unknown ? _IntersectMatch<O, O1, match> : never;
    /**
    Get the intersecting keys of **`O`** & **`O1`**
    (If `match = 'default'`, no type checks are done)
    @param O to check similarities with
    @param O1 to check similarities against
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type IntersectKeys<O extends object, O1 extends object, match extends Match = 'default'> = {
        'default': Intersect<Keys<O>, Keys<O1>>;
        'contains->': IntersectMatch<O, O1, 'contains->'>;
        'extends->': IntersectMatch<O, O1, 'extends->'>;
        'implements->': IntersectMatch<O, O1, 'implements->'>;
        '<-contains': IntersectMatch<O, O1, '<-contains'>;
        '<-extends': IntersectMatch<O, O1, '<-extends'>;
        '<-implements': IntersectMatch<O, O1, '<-implements'>;
        'equals': IntersectMatch<O, O1, 'equals'>;
    }[match];
}
declare module "Object/Intersect" {
    import { IntersectKeys } from "Object/IntersectKeys";
    import { Match } from "Any/_Internal";
    import { Pick } from "Object/Pick";
    /**
    Get the intersecting fields of **`O`** & **`O1`**
    (If `match = 'default'`, no type checks are done)
    @param O to check similarities with
    @param O1 to check similarities against
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Intersect<O extends object, O1 extends object, match extends Match = 'default'> = Pick<O, IntersectKeys<O, O1, match>>;
}
declare module "Object/Invert" {
    import { Record } from "Object/Record";
    import { Key } from "Any/Key";
    import { IntersectOf } from "Union/IntersectOf";
    import { ComputeRaw } from "Any/Compute";
    /**
    @hidden
    */
    export type _Invert<O extends Record<Key, Key>> = ComputeRaw<IntersectOf<{
        [K in keyof O]: Record<O[K], K>;
    }[keyof O]>>;
    /**
    Swaps the keys and values of an [[Object]] (if applicable)
    @param O
    @returns [[Object]]
    @example
    ```ts
    import {O} from 'ts-toolbelt'
    
    enum E {
        A = 'Av',
        B = 'Bv',
        C = 'Cv',
        D = 'Dv',
        X = 1
    }
    
    type O = {
        A: 'Av'
        B: 'Bv'
        C: 'Cv'
        D: 'Dv'
        X: 1
    }
    
    type test0 = O.Invert<typeof E>
    type test1 = O.Invert<O>
    ```
    */
    export type Invert<O extends Record<Key, Key>> = O extends unknown ? _Invert<O> : never;
}
declare module "Object/MergeAll" {
    import { Iteration } from "Iteration/Iteration";
    import { IterationOf } from "Iteration/IterationOf";
    import { Merge } from "Object/Merge";
    import { Pos } from "Iteration/Pos";
    import { Next } from "Iteration/Next";
    import { Length } from "List/Length";
    import { Cast } from "Any/Cast";
    import { List } from "List/List";
    import { Extends } from "Any/Extends";
    import { Depth, MergeStyle } from "Object/_Internal";
    import { BuiltInObject } from "Misc/BuiltInObject";
    /**
    @hidden
    */
    type __MergeAll<O extends object, Os extends List<object>, depth extends Depth, style extends MergeStyle, noMerge extends any, I extends Iteration = IterationOf<'0'>> = {
        0: __MergeAll<Merge<O, Os[Pos<I>], depth, style, noMerge>, Os, depth, style, noMerge, Next<I>>;
        1: O;
    }[Extends<Pos<I>, Length<Os>>];
    /**
    @hidden
    */
    export type _MergeAll<O extends object, Os extends List<object>, depth extends Depth, style extends MergeStyle, noMerge extends any> = __MergeAll<O, Os, depth, style, noMerge> extends infer X ? Cast<X, object> : never;
    /**
    [[Merge]] a list of [[Object]]s into **`O`**. Merges from left to right, first
    items get completed by the next ones (last-in completes).
    @param O to start with
    @param Os to merge
    @param depth (?=`'flat'`) to do it deeply
    @param style (?=`1`) 0 = lodash, 1 = ramda
    @param noMerge (?=`BuiltinObject`) types not to merge
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type MergeAll<O extends object, Os extends List<object>, depth extends Depth = 'flat', style extends MergeStyle = 2, noMerge extends any = BuiltInObject> = O extends unknown ? Os extends unknown ? _MergeAll<O, Os, depth, style, noMerge> : never : never;
}
declare module "Union/Replace" {
    import { Union } from "Union/Union";
    /**
    Replace **`M`** with **`A`** in **`U`**
    @param U to update
    @param M to select
    @param A to update with
    @returns [[Union]]
    @example
    ```ts
    ```
    */
    export type Replace<U extends Union, M extends any, A extends any> = U extends M ? A : U;
}
declare module "Object/Modify" {
    import { At } from "Object/At";
    import { Replace } from "Union/Replace";
    import { x } from "Any/x";
    import { Exclude } from "Union/Exclude";
    /**
    Modify **`O`** with **`OMod`** & the [[x]] placeholder
    @param O to copy from
    @param OMod to copy to
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Modify<O extends object, OMod extends object> = {
        [K in keyof OMod]: Replace<OMod[K], x, Exclude<At<O, K>, undefined>>;
    } & {};
}
declare module "Object/NonNullableKeys" {
    /**
    @hidden
    */
    export type _NonNullableKeys<O extends object> = {
        [K in keyof O]-?: [O[K] & (undefined | null)] extends [never] ? K : never;
    }[keyof O];
    /**
    Get the keys of **`O`** that are non-nullable
    
    (⚠️ needs `--strictNullChecks` enabled)
    @param O
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type NonNullableKeys<O extends object> = O extends unknown ? _NonNullableKeys<O> : never;
}
declare module "Union/Nullable" {
    import { Union } from "Union/Union";
    /**
    Add **`undefined | null`** to **`U`**
    @param U to make nullable
    @returns [[Union]]
    @example
    ```ts
    ```
    */
    export type Nullable<U extends Union> = U | undefined | null;
}
declare module "Object/Nullable" {
    import { Nullable as UNullable } from "Union/Nullable";
    import { Depth } from "Object/_Internal";
    import { _Pick } from "Object/Pick";
    import { Key } from "Any/Key";
    import { _PatchFlat } from "Object/Patch";
    /**
    @hidden
    */
    export type NullableFlat<O> = {
        [K in keyof O]: UNullable<O[K]>;
    } & {};
    /**
    @hidden
    */
    export type NullableDeep<O> = {
        [K in keyof O]: NullableDeep<UNullable<O[K]>>;
    };
    /**
    @hidden
    */
    type NullablePart<O extends object, depth extends Depth> = {
        'flat': NullableFlat<O>;
        'deep': NullableDeep<O>;
    }[depth];
    /**
     * @hidden
     */
    export type _Nullable<O extends object, K extends Key, depth extends Depth> = _PatchFlat<NullablePart<_Pick<O, K>, depth>, O, 2>;
    /**
    Make some fields of **`O`** nullable (deeply or not)
    @param O to make nullable
    @param K (?=`Key`) to choose fields
    @param depth (?=`'flat'`) to do it deeply
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Nullable<O extends object, K extends Key = Key, depth extends Depth = 'flat'> = O extends unknown ? _Nullable<O, K, depth> : never;
}
declare module "Object/NullableKeys" {
    /**
    @hidden
    */
    export type _NullableKeys<O extends object> = {
        [K in keyof O]-?: [O[K] & (undefined | null)] extends [never] ? never : K;
    }[keyof O];
    /**
    Get the keys of **`O`** that are nullable
    
    (⚠️ needs `--strictNullChecks` enabled)
    @param O
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type NullableKeys<O extends object> = O extends unknown ? _NullableKeys<O> : never;
}
declare module "Object/Object" {
    /**
    An [[Object]]
    @example
    ```ts
    type object0 = {a: "hello"}
    type string1 = {b: "world"}
    ```
    */
    export type Object = object;
}
declare module "Object/Partial" {
    import { OptionalPart } from "Object/Optional";
    import { Depth } from "Object/_Internal";
    /**
    Make all fields of **`O`** optional (deeply or not)
    @param O to make optional
    @param depth (?=`'flat'`) to do it deeply
    @returns [[Object]]
    @example
    ```ts
    import {O} from 'ts-toolbelt'
    
    type L = {a: {b: {c: 2}}, b: 1}
    
    type test0 = O.Partial<L>
    type test1 = O.Partial<L, 'deep'>
    ```
     */
    export type Partial<O extends object, depth extends Depth = 'flat'> = OptionalPart<O, depth>;
}
declare module "Object/PatchAll" {
    import { Iteration } from "Iteration/Iteration";
    import { IterationOf } from "Iteration/IterationOf";
    import { Pos } from "Iteration/Pos";
    import { Next } from "Iteration/Next";
    import { Length } from "List/Length";
    import { Cast } from "Any/Cast";
    import { List } from "List/List";
    import { Extends } from "Any/Extends";
    import { Depth, MergeStyle } from "Object/_Internal";
    import { Patch } from "Object/Patch";
    import { BuiltInObject } from "Misc/BuiltInObject";
    /**
    @hidden
    */
    type __PatchAll<O extends object, Os extends List<object>, depth extends Depth, style extends MergeStyle, noMerge extends any, I extends Iteration = IterationOf<'0'>> = {
        0: __PatchAll<Patch<O, Os[Pos<I>], depth, style, noMerge>, Os, depth, style, noMerge, Next<I>>;
        1: O;
    }[Extends<Pos<I>, Length<Os>>];
    /**
    @hidden
    */
    export type _PatchAll<O extends object, Os extends List<object>, depth extends Depth, style extends MergeStyle, noMerge extends any> = __PatchAll<O, Os, depth, style, noMerge> extends infer X ? Cast<X, object> : never;
    /**
    [[Patch]] a list of [[Object]]s into **`O`**. Patches from left to right, first
    items get completed by the next ones (last-in completes).
    @param O to start with
    @param Os to patch
    @param depth (?=`'flat'`) to do it deeply
    @param style (?=`1`) 0 = lodash, 1 = ramda
    @param noMerge (?=`BuiltinObject`) types not to merge
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type PatchAll<O extends object, Os extends List<object>, depth extends Depth = 'flat', style extends MergeStyle = 2, noMerge extends any = BuiltInObject> = O extends unknown ? Os extends unknown ? _PatchAll<O, Os, depth, style, noMerge> : never : never;
}
declare module "Object/Paths" {
    import { OptionalFlat } from "Object/Optional";
    import { Key } from "Any/Key";
    import { NonNullableFlat } from "Object/NonNullable";
    import { _Concat } from "List/Concat";
    import { Cast } from "Any/Cast";
    import { Equals } from "Any/Equals";
    import { List } from "List/List";
    import { _Append } from "List/Append";
    /**
    @hidden
    */
    type __Paths<O, Paths extends List<Key> = []> = {
        0: {
            [K in keyof O]: __Paths<O[K], _Append<Paths, K>>;
        }[keyof O];
        1: NonNullableFlat<OptionalFlat<Paths>>;
        2: NonNullableFlat<OptionalFlat<_Concat<Paths, Key[]>>>;
    }[Equals<O, any> extends 1 ? 2 : O extends object ? [keyof O] extends [never] ? 1 : 0 : 1];
    /**
    @hidden
    */
    export type _Paths<O extends object> = __Paths<O> extends infer X ? Cast<X, List<Key>> : never;
    /**
    Get all the possible paths of **`O`**
    (⚠️ this won't work with circular-refs)
    @param O to be inspected
    @returns **`string[]`**
    @example
    ```ts
    ```
    */
    export type Paths<O extends object> = O extends unknown ? _Paths<O> : never;
}
declare module "Object/Update" {
    import { Key } from "Any/Key";
    import { x } from "Any/x";
    import { Replace } from "Union/Replace";
    import { Depth } from "Object/_Internal";
    /**
     * @hidden
     */
    type UpdateFlat<O extends object, K extends Key, A extends any> = {
        [P in keyof O]: P extends K ? Replace<A, x, O[P]> : O[P];
    } & {};
    /**
     * @hidden
     */
    type __UpdateDeep<O, A extends any> = {
        [K in keyof O]: Replace<A, x, O[K]> extends infer X ? X extends object ? __UpdateDeep<X, A> : X : never;
    };
    /**
     * @hidden
     */
    type _UpdateDeep<O extends object, K extends Key, A extends any, OU = Update<O, K, x | A>> = {
        [K in keyof OU]: __UpdateDeep<OU[K], A>;
    } & {};
    /**
     * @hidden
     */
    export type UpdateDeep<O extends object, K extends Key, A extends any> = _UpdateDeep<O, K, A>;
    /**
    Update in **`O`** the fields of key **`K`** with **`A`**.
    Use the [[x]] placeholder to get the current field type.
    @param O to update
    @param K to chose fields
    @param A to update with
    @returns [[Object]]
    @example
    ```ts
    import {A, O} from 'ts-toolbelt'
    
    type User = {
        info: {
            name: string
            age: number
            payment: {}
        }
        id: number
    }
    
    type test0 = Update<User, 'id' | 'info', A.x | null>
    // {
    //     info: {
    //         name: string;
    //         age: number;
    //         payment: {};
    //     } | null;
    //     id: number | null;
    // }
    ```
    */
    export type Update<O extends object, K extends Key, A extends any, depth extends Depth = 'flat'> = {
        'flat': UpdateFlat<O, K, A>;
        'deep': UpdateDeep<O, K, A>;
    }[depth];
}
declare module "List/Update" {
    import { Key } from "Any/Key";
    import { List } from "List/List";
    import { Update as OUpdate } from "Object/Update";
    import { Depth } from "Object/_Internal";
    /**
    Update in **`L`** the entries of key **`K`** with **`A`**.
    Use the [[x]] placeholder to get the current field type.
    @param L to update
    @param K to chose fields
    @param A to update with
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Update<L extends List, K extends Key, A extends any, depth extends Depth = 'flat'> = OUpdate<L, K, A, depth>;
}
declare module "Object/PathValid" {
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Next } from "Iteration/Next";
    import { Pos } from "Iteration/Pos";
    import { At } from "Object/At";
    import { Cast } from "Any/Cast";
    import { NonNullable } from "Union/NonNullable";
    import { Update } from "List/Update";
    import { Key } from "Iteration/Key";
    import { Key as AKey } from "Any/Key";
    import { List } from "List/List";
    import { Length } from "List/Length";
    import { Extends } from "Any/Extends";
    /**
    @hidden
    */
    type ValidatePath<O, Path extends List<AKey>, I extends Iteration> = Update<Path, Key<I>, [
        At<O & {}, Path[Pos<I>]>
    ] extends [never] ? keyof O : Path[Pos<I>]>;
    /**
    @hidden
    */
    type __PathValid<O, Path extends List<AKey>, I extends Iteration = IterationOf<'0'>> = {
        0: __PathValid<NonNullable<At<O & {}, Path[Pos<I>]>>, ValidatePath<O, Path, I>, Next<I>>;
        1: Path;
    }[Extends<Pos<I>, Length<Path>>];
    /**
    @hidden
    */
    export type _PathValid<O extends object, Path extends List<AKey>> = __PathValid<O, Path> extends infer X ? Cast<X, List<AKey>> : never;
    /**
     * Replaces invalid parts of a path with `never`
     * @param O to be inspected
     * @param Path to be validated
     * @returns **`Index[]`**
     * @example
     * ```ts
     * import {A, L, O} from 'ts-toolbelt'
     *
     * // Get a property in an object `o` at any depth with `path`
     * // `A.Cast<P, O.PathValid<O, P>>` makes sure `path` is valid
     * const getAt = <
     * O extends object,
     * P extends L.List<A.Index>
     * >(o: O, path: A.Cast<P, O.PathValid<O, P>>): O.Path<O, P> => {
     *     let valueAt = o
     *
     *     for (const p of path)
     *         valueAt = valueAt[p]
     *
     *     return valueAt as any
     * }
     *
     * const test0 = getAt({a: {b: {c: 1}}},          ['a', 'b'] as const) // {c: number}
     * const test1 = getAt({a: {b: {c: 1}}} as const, ['a', 'b'] as const) // {c: 1}
     * const test2 = getAt({a: {b: {c: 1}}},          ['x'] as const)      // error
     * ```
     */
    export type PathValid<O extends object, Path extends List<AKey>> = O extends unknown ? Path extends unknown ? _PathValid<O, Path> : never : never;
}
declare module "Object/ReadonlyKeys" {
    import { Equals } from "Any/Equals";
    /**
    @hidden
    */
    export type _ReadonlyKeys<O extends object> = {
        [K in keyof O]-?: {
            1: never;
            0: K;
        }[Equals<{
            -readonly [Q in K]: O[K];
        }, {
            [Q in K]: O[K];
        }>];
    }[keyof O];
    /**
    Get the keys of **`O`** that are readonly
    @param O
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type ReadonlyKeys<O extends object> = O extends unknown ? _ReadonlyKeys<O> : never;
}
declare module "Object/Replace" {
    import { Match } from "Any/_Internal";
    import { Is } from "Any/Is";
    /**
    @hidden
    */
    export type _Replace<O extends object, M extends any, A extends any, match extends Match> = {
        [K in keyof O]: {
            1: A;
            0: O[K];
        }[Is<M, O[K], match>];
    } & {};
    /**
    Update with **`A`** the fields of **`O`** that match **`M`**
    @param O to update
    @param M to select fields
    @param A to update with
    @param match (?=`'default'`) to change precision
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Replace<O extends object, M extends any, A extends any, match extends Match = 'default'> = O extends unknown ? _Replace<O, M, A, match> : never;
}
declare module "Object/RequiredKeys" {
    /**
    @hidden
    */
    export type _RequiredKeys<O extends object> = {
        [K in keyof O]-?: {} extends Pick<O, K> ? never : K;
    }[keyof O];
    /**
    Get the keys of **`O`** that are required
    @param O
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type RequiredKeys<O extends object> = O extends unknown ? _RequiredKeys<O> : never;
}
declare module "Object/Select" {
    import { SelectKeys } from "Object/SelectKeys";
    import { Match } from "Any/_Internal";
    import { Pick } from "Object/Pick";
    /**
    Extract the fields of **`O`** that match **`M`**
    @param O to extract from
    @param M to select fields
    @param match (?=`'default'`) to change precision
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Select<O extends object, M extends any, match extends Match = 'default'> = Pick<O, SelectKeys<O, M, match>>;
}
declare module "Object/Undefinable" {
    import { Depth } from "Object/_Internal";
    import { _Pick } from "Object/Pick";
    import { Key } from "Any/Key";
    import { _PatchFlat } from "Object/Patch";
    import { BuiltInObject } from "Misc/BuiltInObject";
    /**
    @hidden
    */
    export type UndefinableFlat<O> = {
        [K in keyof O]: O[K] | undefined;
    } & {};
    /**
    @hidden
    */
    export type UndefinableDeep<O> = {
        [K in keyof O]: O[K] extends BuiltInObject ? O[K] : UndefinableDeep<O[K] | undefined>;
    };
    /**
    @hidden
    */
    type UndefinablePart<O extends object, depth extends Depth> = {
        'flat': UndefinableFlat<O>;
        'deep': UndefinableDeep<O>;
    }[depth];
    /**
     * @hidden
     */
    export type _Undefinable<O extends object, K extends Key, depth extends Depth> = _PatchFlat<UndefinablePart<_Pick<O, K>, depth>, O, 2>;
    /**
    Make some fields of **`O`** **`undefined`** (deeply or not)
    @param O to make undefinable
    @param K (?=`Key`) to choose fields
    @param depth (?=`'flat'`) to do it deeply
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Undefinable<O extends object, K extends Key = Key, depth extends Depth = 'flat'> = O extends unknown ? _Undefinable<O, K, depth> : never;
}
declare module "Object/UndefinableKeys" {
    /**
    @hidden
    */
    export type _UndefinableKeys<O extends object> = {
        [K in keyof O]-?: [O[K] & (undefined)] extends [never] ? never : K;
    }[keyof O];
    /**
    Get the keys of **`O`** that are **`undefined`**
    (⚠️ needs `--strictNullChecks` enabled)
    @param O
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type UndefinableKeys<O extends object> = O extends unknown ? _UndefinableKeys<O> : never;
}
declare module "Object/Unionize" {
    import { At } from "Object/At";
    import { Key } from "Any/Key";
    /**
    Make the fields of **`O`** union the ones of **`O1`**
    @param O to union from
    @param O1 to union with
    @param K (?=`Key`) to chose fields
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Unionize<O extends object, O1 extends object, K extends Key = Key> = {
        [P in keyof O]: P extends K ? O[P] | At<O1, P> : O[P];
    } & {};
}
declare module "Object/Writable" {
    import { _Pick } from "Object/Pick";
    import { Depth } from "Object/_Internal";
    import { Key } from "Any/Key";
    import { _PatchFlat } from "Object/Patch";
    import { BuiltInObject } from "Misc/BuiltInObject";
    /**
    @hidden
    */
    export type WritableFlat<O> = {
        -readonly [K in keyof O]: O[K];
    } & {};
    /**
    @hidden
    */
    export type WritableDeep<O> = {
        -readonly [K in keyof O]: O[K] extends BuiltInObject ? O[K] : WritableDeep<O[K]>;
    };
    /**
    @hidden
    */
    export type WritablePart<O extends object, depth extends Depth> = {
        'flat': WritableFlat<O>;
        'deep': WritableDeep<O>;
    }[depth];
    /**
    @hidden
    */
    export type _Writable<O extends object, K extends Key, depth extends Depth> = _PatchFlat<WritablePart<_Pick<O, K>, depth>, O, 2>;
    /**
    Make some fields of **`O`** writable (deeply or not)
    @param O to make writable
    @param K (?=`Key`) to choose fields
    @param depth (?=`'flat'`) to do it deeply
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Writable<O extends object, K extends Key = Key, depth extends Depth = 'flat'> = O extends unknown ? _Writable<O, K, depth> : never;
}
declare module "Object/WritableKeys" {
    import { Equals } from "Any/Equals";
    /**
    @hidden
    */
    export type _WritableKeys<O extends object> = {
        [K in keyof O]-?: {
            1: K;
            0: never;
        }[Equals<{
            -readonly [Q in K]: O[K];
        }, {
            [Q in K]: O[K];
        }>];
    }[keyof O];
    /**
    Get the keys of **`O`** that are writable
    @param O
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type WritableKeys<O extends object> = O extends unknown ? _WritableKeys<O> : never;
}
declare module "Object/_api" {
    /** @ignore */ /** */
    import * as P from "Object/P/_api";
    export { P };
    export { Assign } from "Object/Assign";
    export { At } from "Object/At";
    export { AtLeast } from "Object/AtLeast";
    export { Compulsory } from "Object/Compulsory";
    export { CompulsoryKeys } from "Object/CompulsoryKeys";
    export { Diff } from "Object/Diff";
    export { Either } from "Object/Either";
    export { Exclude } from "Object/Exclude";
    export { ExcludeKeys } from "Object/ExcludeKeys";
    export { Filter } from "Object/Filter";
    export { FilterKeys } from "Object/FilterKeys";
    export { Has } from "Object/Has";
    export { HasPath } from "Object/HasPath";
    export { Includes } from "Object/Includes";
    export { Intersect } from "Object/Intersect";
    export { IntersectKeys } from "Object/IntersectKeys";
    export { Invert } from "Object/Invert";
    export { Keys } from "Object/Keys";
    export { ListOf } from "Object/ListOf";
    export { Patch as Merge } from "Object/Patch";
    export { MergeAll } from "Object/MergeAll";
    export { Modify } from "Object/Modify";
    export { NonNullable } from "Object/NonNullable";
    export { NonNullableKeys } from "Object/NonNullableKeys";
    export { Nullable } from "Object/Nullable";
    export { NullableKeys } from "Object/NullableKeys";
    export { Object } from "Object/Object";
    export { Omit } from "Object/Omit";
    export { Optional } from "Object/Optional";
    export { OptionalKeys } from "Object/OptionalKeys";
    export { Overwrite } from "Object/Overwrite";
    export { Partial } from "Object/Partial";
    export { Patch } from "Object/Patch";
    export { PatchAll } from "Object/PatchAll";
    export { Path } from "Object/Path";
    export { Paths } from "Object/Paths";
    export { PathValid } from "Object/PathValid";
    export { Pick } from "Object/Pick";
    export { Readonly } from "Object/Readonly";
    export { ReadonlyKeys } from "Object/ReadonlyKeys";
    export { Record } from "Object/Record";
    export { Replace } from "Object/Replace";
    export { Required } from "Object/Required";
    export { RequiredKeys } from "Object/RequiredKeys";
    export { Select } from "Object/Select";
    export { SelectKeys } from "Object/SelectKeys";
    export { Undefinable } from "Object/Undefinable";
    export { UndefinableKeys } from "Object/UndefinableKeys";
    export { Unionize } from "Object/Unionize";
    export { UnionOf } from "Object/UnionOf";
    export { Update } from "Object/Update";
    export { Writable } from "Object/Writable";
    export { WritableKeys } from "Object/WritableKeys";
    export { Merge as MergeUp } from "Object/Merge";
    export { Assign as AssignUp } from "Object/Assign";
    export { PatchAll as Compact } from "Object/PatchAll";
    export { MergeAll as CompactUp } from "Object/MergeAll";
}
declare module "String/String" {
    /**
    A [[String]]
    @example
    ```ts
    type string0 = "hello"
    type string1 = "world"
    ```
    */
    export type String = string;
}
declare module "String/_api" {
    /** @ignore */ /** */
    export { Format } from "String/Format";
    export { String } from "String/String";
}
declare module "List/Assign" {
    import { Assign as OAssign } from "Object/Assign";
    import { List } from "List/List";
    import { ObjectOf } from "List/ObjectOf";
    import { ListOf } from "Object/ListOf";
    import { Depth } from "Object/_Internal";
    /**
    Assign a list of [[List]] into **`L`** with [[Merge]]. Merges from left to
    right, first items get overridden by the next ones (last-in overrides).
    @param L to assign to
    @param Ls to assign
    @param depth (?=`'flat'`) to do it deeply
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Assign<L extends List, Ls extends List<List>, depth extends Depth = 'flat'> = ListOf<OAssign<ObjectOf<L>, {
        [K in keyof Ls]: ObjectOf<Ls[K] & List>;
    }, depth>>;
}
declare module "List/At" {
    import { At as OAt } from "Object/At";
    import { Key } from "Any/Key";
    import { List } from "List/List";
    import { Boolean } from "Boolean/Boolean";
    /**
    Get in **`L`** the type of an entry of key **`K`**
    @param L to extract from
    @param K to extract at
    @param strict (?=`1`) `0` to work with unions
    @returns **`any`**
    @example
    */
    export type At<L extends List, K extends Key, strict extends Boolean = 1> = OAt<L, K, strict>;
}
declare module "List/Keys" {
    import { Exclude } from "Union/Exclude";
    import { List } from "List/List";
    import { Keys as UKeys } from "Union/Keys";
    /**
    Get the keys of a [[List]]
    @param L
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type Keys<L extends List> = Exclude<UKeys<L>, keyof any[]> | number;
}
declare module "List/AtLeast" {
    import { Key } from "Any/Key";
    import { AtLeast as OAtLeast } from "Object/AtLeast";
    import { ObjectOf } from "List/ObjectOf";
    import { _ListOf } from "Object/ListOf";
    import { List } from "List/List";
    import { NumberOf } from "Any/_Internal";
    import { Keys } from "List/Keys";
    /**
    Make that at least one of the keys **`K`** are required in **`L`** at a time.
    @param L to make required
    @param K (?=`keyof L`) to choose fields
    @returns [[List]] [[Union]]
    @example
    ```ts
    ```
    */
    export type AtLeast<L extends List, K extends Key = Keys<L>> = OAtLeast<ObjectOf<L>, NumberOf<K>> extends infer U ? U extends unknown ? _ListOf<U & {}> : never : never;
}
declare module "List/Compulsory" {
    import { Depth } from "Object/_Internal";
    import { CompulsoryPart } from "Object/Compulsory";
    import { List } from "List/List";
    /**
    Make that **`L`**'s fields cannot be [[Nullable]] or [[Optional]] (it's like
    [[Required]] & [[NonNullable]] at once).
    @param L to make compulsory
    @param depth (?=`'flat'`) to do it deeply
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Compulsory<L extends List, depth extends Depth = 'flat'> = CompulsoryPart<L, depth>;
}
declare module "List/CompulsoryKeys" {
    import { Compulsory as OCompulsory } from "Object/Compulsory";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Get the keys of **`L`** that are [[Compulsory]]
    
    (⚠️ needs `--strictNullChecks` enabled)
    @param L
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type CompulsoryKeys<L extends List> = OCompulsory<ObjectOf<L>>;
}
declare module "List/Diff" {
    import { Diff as ODiff } from "Object/Diff";
    import { ListOf } from "Object/ListOf";
    import { Match } from "Any/_Internal";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Get a [[List]] that is the difference between **`L`** & **`L1`**
    (**`L`**'s differences have priority over **`L1`**'s if entries overlap)
    (If `match = 'default'`, no type checks are done)
    @param L to check differences with
    @param L1 to check differences against
    @param match (?=`'default'`) to change precision
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Diff<L extends List, L1 extends List, match extends Match = 'default'> = ListOf<ODiff<ObjectOf<L>, ObjectOf<L1>, match>>;
}
declare module "List/Drop" {
    import { Tail } from "List/Tail";
    import { Cast } from "Any/Cast";
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Number } from "Number/Number";
    import { Way } from "Iteration/_Internal";
    import { List } from "List/List";
    import { Pos } from "Iteration/Pos";
    import { Prev } from "Iteration/Prev";
    import { Prepend } from "List/Prepend";
    import { Naked } from "List/_Internal";
    import { Extends } from "Any/Extends";
    /**
    @hidden
    */
    type DropForth<L extends List, N extends Iteration> = {
        0: DropForth<Tail<L>, Prev<N>>;
        1: L;
    }[Extends<0, Pos<N>>];
    /**
    @hidden
    */
    type DropBack<L extends List, N extends Iteration, I extends Iteration = Prev<N>, LN extends List = []> = {
        0: DropBack<L, N, Prev<I>, Prepend<LN, L[Pos<I>]>>;
        1: LN;
    }[Extends<-1, Pos<I>>];
    /**
    @hidden
    */
    type __Drop<L extends List, N extends Iteration, way extends Way> = {
        '->': DropForth<L, N>;
        '<-': DropBack<L, N>;
    }[way];
    /**
    @hidden
    */
    export type _Drop<L extends List, N extends Number, way extends Way = '->'> = __Drop<Naked<L>, IterationOf<N>, way> extends infer X ? Cast<X, List> : never;
    /**
    Remove **`N`** entries out of **`L`**
    @param L to remove from
    @param N to remove out
    @param way (?=`'->'`) from front: '->', from end: '<-'
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Drop<L extends List, N extends Number, way extends Way = '->'> = L extends unknown ? N extends unknown ? _Drop<L, N, way> : never : never;
}
declare module "List/Either" {
    import { Key } from "Any/Key";
    import { Either as OEither } from "Object/Either";
    import { ObjectOf } from "List/ObjectOf";
    import { _ListOf } from "Object/ListOf";
    import { List } from "List/List";
    import { Boolean } from "Boolean/Boolean";
    import { NumberOf } from "Any/_Internal";
    /**
    Split **`L`** into a [[Union]] with **`K`** keys in such a way that none of
    the keys are ever present with one another within the different unions.
    @param L to split
    @param K to split with
    @param strict (?=`1`) to force excess property checks https://github.com/microsoft/TypeScript/issues/20863
    @returns [[List]] [[Union]]
    @example
    ```ts
    ```
    */
    export type Either<L extends List, K extends Key, strict extends Boolean = 1> = OEither<ObjectOf<L>, NumberOf<K>, strict> extends infer OE ? OE extends unknown ? _ListOf<OE & {}> : never : never;
}
declare module "List/Exclude" {
    import { Match } from "Any/_Internal";
    import { ListOf } from "Object/ListOf";
    import { Exclude as OExclude } from "Object/Exclude";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Exclude the entries of **`L1`** out of **`L`**
    (If `match = 'default'`, no type checks are done)
    @param L to remove from
    @param L1 to remove out
    @param match (?=`'default'`) to change precision
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Exclude<L extends List, L1 extends List, match extends Match = 'default'> = ListOf<OExclude<ObjectOf<L>, ObjectOf<L1>, match>>;
}
declare module "List/ExcludeKeys" {
    import { ExcludeKeys as OExcludeKeys } from "Object/ExcludeKeys";
    import { Match } from "Any/_Internal";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Exclude the keys of **`L1`** out of the keys of **`L`**
    (If `match = 'default'`, no type checks are done)
    @param L to remove the keys from
    @param L1 to remove the keys out
    @param match (?=`'default'`) to change precision
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type ExcludeKeys<L extends List, L1 extends List, match extends Match = 'default'> = OExcludeKeys<ObjectOf<L>, ObjectOf<L1>, match>;
}
declare module "List/UnionOf" {
    import { List } from "List/List";
    /**
    Transform a [[List]] into an [[Union]]
    @param L to transform
    @returns **`any`**
    @example
    ```ts
    ```
    */
    export type UnionOf<L extends List> = L[number];
}
declare module "List/KeySet" {
    import { Number } from "Number/Number";
    import { Range } from "Number/Range";
    import { UnionOf } from "List/UnionOf";
    /**
    Create a set of keys
    @param From to start with
    @param To to end with
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type KeySet<From extends Number, To extends Number> = UnionOf<Range<From, To, '->'>>;
}
declare module "List/Extract" {
    import { KeySet } from "List/KeySet";
    import { Number } from "Number/Number";
    import { Pick } from "List/Pick";
    import { List } from "List/List";
    /**
    Pick a range of entries (portion) from **`L`**
    @param L to pick from
    @param From to start with
    @param To to end with
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Extract<L extends List, From extends Number, To extends Number> = Pick<L, KeySet<From, To>>;
}
declare module "List/Filter" {
    import { Filter as OFilter } from "Object/Filter";
    import { ListOf } from "Object/ListOf";
    import { Match } from "Any/_Internal";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Filter out of **`L`** the entries that match **`M`**
    @param L to remove from
    @param M to select entries
    @param match (?=`'default'`) to change precision
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Filter<L extends List, M extends any, match extends Match = 'default'> = ListOf<OFilter<ObjectOf<L>, M, match>>;
}
declare module "List/FilterKeys" {
    import { FilterKeys as OFilterKeys } from "Object/FilterKeys";
    import { Match } from "Any/_Internal";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Filter out the keys of **`L`** which entries match **`M`**
    @param L to remove from
    @param M to select entries
    @param match (?=`'default'`) to change precision
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type FilterKeys<L extends List, M extends any, match extends Match = 'default'> = OFilterKeys<ObjectOf<L>, M, match>;
}
declare module "List/UnNest" {
    import { _Concat } from "List/Concat";
    import { _Append } from "List/Append";
    import { Cast } from "Any/Cast";
    import { Length } from "List/Length";
    import { Iteration } from "Iteration/Iteration";
    import { IterationOf } from "Iteration/IterationOf";
    import { Next } from "Iteration/Next";
    import { Pos } from "Iteration/Pos";
    import { List } from "List/List";
    import { UnionOf } from "List/UnionOf";
    import { Naked } from "List/_Internal";
    import { Extends } from "Any/Extends";
    import { Boolean } from "Boolean/Boolean";
    import { Not } from "Boolean/Not";
    import { And } from "Boolean/And";
    /**
    @hidden
    */
    type UnNestLoose<L extends List> = (UnionOf<L> extends infer UL ? UL extends unknown ? UL extends List ? UnionOf<UL> : UL : never : never)[] & {};
    /**
    @hidden
    */
    type Flatter<L extends List, LN extends List, I extends Iteration> = L[Pos<I>] extends infer LP ? LP extends List ? _Concat<LN, L[Pos<I>]> : _Append<LN, L[Pos<I>]> : never;
    /**
    @hidden
    */
    type UnNestStrict<L extends List, LN extends List = [], I extends Iteration = IterationOf<'0'>> = {
        0: UnNestStrict<L, Flatter<L, LN, I>, Next<I>>;
        1: LN;
    }[Extends<Pos<I>, Length<L>>];
    /**
    @hidden
    */
    type __UnNest<L extends List, strict extends Boolean> = {
        0: UnNestLoose<L>;
        1: UnNestStrict<L>;
    }[And<Not<Extends<number, Length<L>>>, strict>];
    /**
    @hidden
    */
    export type _UnNest<L extends List, strict extends Boolean> = __UnNest<Naked<L>, strict> extends infer X ? Cast<X, List> : never;
    /**
    Remove a dimension of **`L`**
    @param L to un-nest
    @param strict (?=`1`) `0` to not preserve tuples
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type UnNest<L extends List, strict extends Boolean = 1> = L extends unknown ? _UnNest<L, strict> : never;
}
declare module "List/Flatten" {
    import { List } from "List/List";
    import { _UnNest } from "List/UnNest";
    import { Cast } from "Any/Cast";
    import { Equals } from "Any/Equals";
    import { Number } from "Number/Number";
    import { Iteration } from "Iteration/Iteration";
    import { IterationOf } from "Iteration/IterationOf";
    import { Extends } from "Any/Extends";
    import { Next } from "Iteration/Next";
    import { Or } from "Boolean/Or";
    import { Boolean } from "Boolean/Boolean";
    /**
    @hidden
    */
    type __Flatten<L extends List, LO extends List, strict extends Boolean, limit extends Iteration, I extends Iteration = IterationOf<'0'>> = {
        0: __Flatten<_UnNest<L, strict>, L, strict, limit, Next<I>>;
        1: L;
    }[Or<Equals<L, LO>, Extends<limit, I>>];
    /**
    @hidden
    */
    export type _Flatten<L extends List, strict extends Boolean, limit extends Number = string> = __Flatten<L, [], strict, IterationOf<limit>> extends infer X ? Cast<X, List> : never;
    /**
    Remove all dimensions of **`L`** (10 max)
    @param L to un-nest
    @param strict (?=`1`) `0` to not preserve tuples
    @param limit (?=`string`) to stop un-nesting at
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Flatten<L extends List, strict extends Boolean = 1, limit extends Number = string> = L extends unknown ? _Flatten<L, strict, limit> : never;
}
declare module "List/Take" {
    import { Number } from "Number/Number";
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Pos } from "Iteration/Pos";
    import { Prepend } from "List/Prepend";
    import { Way } from "Iteration/_Internal";
    import { List } from "List/List";
    import { Prev } from "Iteration/Prev";
    import { Cast } from "Any/Cast";
    import { Tail } from "List/Tail";
    import { Extends } from "Any/Extends";
    /**
    starts in reverse from `N` till `N` = 0
    @hidden
    */
    type TakeForth<L extends List, N extends Iteration, I extends Iteration = Prev<N>, LN extends List = []> = {
        0: TakeForth<L, N, Prev<I>, Prepend<LN, L[Pos<I>]>>;
        1: LN;
    }[Extends<-1, Pos<I>>];
    /**
    starts in reverse from the end till `N` = 0
    @hidden
    */
    type TakeBack<L extends List, N extends Iteration> = {
        0: TakeBack<Tail<L>, Prev<N>>;
        1: L;
    }[Extends<0, Pos<N>>];
    /**
    @hidden
    */
    type __Take<L extends List, N extends Iteration, way extends Way> = {
        '->': TakeForth<L, N>;
        '<-': TakeBack<L, N>;
    }[way];
    /**
    @hidden
    */
    export type _Take<L extends List, N extends Number, way extends Way = '->'> = __Take<L, IterationOf<N>, way> extends infer X ? Cast<X, List> : never;
    /**
    Extract **`N`** entries out of **`L`**
    @param L to extract from
    @param N to extract out
    @param way (?=`'->'`) to extract from end
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Take<L extends List, N extends Number, way extends Way = '->'> = L extends unknown ? N extends unknown ? _Take<L, N, way> : never : never;
}
declare module "List/Group" {
    import { Number } from "Number/Number";
    import { _Drop } from "List/Drop";
    import { _Take } from "List/Take";
    import { Cast } from "Any/Cast";
    import { Prepend } from "List/Prepend";
    import { _Reverse } from "List/Reverse";
    import { List } from "List/List";
    import { Extends } from "Any/Extends";
    /**
    @hidden
    */
    type __Group<L extends List, N extends Number, LN extends List = []> = {
        0: __Group<_Drop<L, N>, N, Prepend<LN, _Take<L, N>>>;
        1: _Reverse<LN>;
    }[Extends<L, List<never>>];
    /**
    @hidden
    */
    export type _Group<L extends List, N extends Number> = __Group<L, N> extends infer X ? Cast<X, List> : never;
    /**
    Split **`L`** into sub-[[List]]s every **`N`**
    @param L to group
    @param N to split at
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Group<L extends List, N extends Number> = L extends unknown ? N extends unknown ? _Group<L, N> : never : never;
}
declare module "List/Has" {
    import { Match, NumberOf } from "Any/_Internal";
    import { Has as OHas } from "Object/Has";
    import { Key } from "Any/Key";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Check whether **`L`** has a entry of key **`K`** that matches **`M`**
    @param L to be inspected
    @param K to choose entry
    @param M (?=`any`) to check entry type
    @param match (?=`'default'`) to change precision
    @returns [[Boolean]]
    @example
    ```ts
    ```
    */
    export type Has<L extends List, K extends Key, M extends any = any, match extends Match = 'default'> = OHas<ObjectOf<L>, NumberOf<K>, M, match>;
}
declare module "List/HasPath" {
    import { HasPath as OHasPath } from "Object/HasPath";
    import { Match } from "Any/_Internal";
    import { Key } from "Any/Key";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Check whether **`L`** has nested entries that match **`M`**
    @param L to be inspected
    @param Path to be followed
    @param M (?=`any`) to check entry type
    @param match (?=`'default'`) to change precision
    @returns [[Boolean]]
    @example
    ```ts
    ```
    */
    export type HasPath<L extends List, Path extends List<Key>, M extends any = any, match extends Match = 'default'> = OHasPath<ObjectOf<L>, Path, M, match>;
}
declare module "List/Includes" {
    import { Match } from "Any/_Internal";
    import { Includes as OIncludes } from "Object/Includes";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Check whether **`L`** has entries that match **`M`**
    @param L to be inspected
    @param M to check entry type
    @param match (?=`'default'`) to change precision
    @returns [[Boolean]]
    @example
    ```ts
    ```
    */
    export type Includes<L extends List, M extends any, match extends Match = 'default'> = OIncludes<ObjectOf<L>, M, match>;
}
declare module "List/Intersect" {
    import { Intersect as OIntersect } from "Object/Intersect";
    import { Match } from "Any/_Internal";
    import { ListOf } from "Object/ListOf";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Get the intersecting entries of **`L`** & **`L1`**
    (If `match = 'default'`, no type checks are done)
    @param L to check similarities with
    @param L1 to check similarities against
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Intersect<L extends List, L1 extends List, match extends Match = 'default'> = ListOf<OIntersect<ObjectOf<L>, ObjectOf<L1>, match>>;
}
declare module "List/IntersectKeys" {
    import { Match } from "Any/_Internal";
    import { IntersectKeys as OIntersectKeys } from "Object/IntersectKeys";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Get the intersecting entries of **`L`** & **`L1`**
    (If `match = 'default'`, no type checks are done)
    @param L to check similarities with
    @param L1 to check similarities against
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type IntersectKeys<L extends List, L1 extends List, match extends Match = 'default'> = OIntersectKeys<ObjectOf<L>, L1, match>;
}
declare module "List/Longest" {
    import { Exclude } from "Union/Exclude";
    import { List } from "List/List";
    import { Keys } from "List/Keys";
    /**
    Get the longest [[List]] of **`L`** & **`L1`**
    (**`L`** has priority if both lengths are equal)
    @param L to compare length
    @param L1 to compare length
    @returns **`L`** or **`L1`**
    @example
    ```ts
    ```
    */
    export type Longest<L extends List, L1 extends List> = [
        Exclude<Keys<L1>, Keys<L>>
    ] extends [never] ? L : L1;
}
declare module "List/Patch" {
    import { Patch as OPatch } from "Object/Patch";
    import { List } from "List/List";
    import { Depth } from "Object/_Internal";
    import { BuiltInObject } from "Misc/BuiltInObject";
    /**
    Complete the fields of **`L`** with the ones of **`L1`**. This is a version of
    [[Merge]] that does NOT handle optional fields, it only completes fields of `O`
    with the ones of `O1` if they don't exist.
    
    (⚠️ needs `--strictNullChecks` enabled)
    @param L to complete
    @param L1 to copy from
    @param depth (?=`'flat'`) to do it deeply
    @param style (?=`1`) 0 = lodash, 1 = ramda
    @param noMerge (?=`BuiltinObject`) types not to merge
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Patch<L extends List, L1 extends List, depth extends Depth = 'flat', noMerge extends any = BuiltInObject> = OPatch<L, L1, depth, 0, noMerge>;
}
declare module "List/MergeAll" {
    import { MergeAll as OMergeAll } from "Object/MergeAll";
    import { List } from "List/List";
    import { Depth } from "Object/_Internal";
    /**
    [[Merge]] a list of [[List]]s into **`L`**. Merges from left to right, first
    items get completed by the next ones (last-in completes).
    @param O to start with
    @param Os to merge
    @param depth (?=`'flat'`) to do it deeply
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type MergeAll<O extends List, Ls extends List<List>, depth extends Depth = 'flat'> = OMergeAll<O, Ls, depth, 0>;
}
declare module "List/Modify" {
    import { At } from "List/At";
    import { Replace } from "Union/Replace";
    import { x } from "Any/x";
    import { List } from "List/List";
    /**
    Modify **`L`** with **`LMod`** & the [[x]] placeholder
    @param L to copy from
    @param LMod to copy to
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Modify<L extends List, LMod extends List> = {
        [K in keyof LMod]: Replace<LMod[K], x, Exclude<At<L, K>, undefined>>;
    } & {};
}
declare module "List/NonNullable" {
    import { Key } from "Any/Key";
    import { NonNullable as UNonNullable } from "Union/NonNullable";
    import { Depth } from "Object/_Internal";
    import { BuiltInObject } from "Misc/BuiltInObject";
    /**
     * @hidden
     */
    export type NonNullableFlat<O, K extends Key = Key> = {
        [P in keyof O]: P extends K ? UNonNullable<O[P]> : O[P];
    } & {};
    /**
     * @hidden
     */
    type _NonNullableDeep<O> = {
        [K in keyof O]: O[K] extends BuiltInObject ? O[K] : NonNullableDeep<O[K], Key>;
    };
    /**
     * @hidden
     */
    export type NonNullableDeep<O, K extends Key = Key> = _NonNullableDeep<NonNullableFlat<O, K>>;
    /**
     * @hidden
     */
    export type NonNullablePart<O extends object, K extends Key, depth extends Depth> = {
        'flat': NonNullableFlat<O, K>;
        'deep': NonNullableDeep<O, K>;
    }[depth];
    /**
    Make some entries of **`L`** not nullable (deeply or not)
    @param L to make non nullable
    @param K (?=`Key`) to choose fields
    @param depth (?=`'flat'`) to do it deeply
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type NonNullable<O extends object, K extends Key = Key, depth extends Depth = 'flat'> = NonNullablePart<O, K, depth>;
}
declare module "List/NonNullableKeys" {
    import { NonNullableKeys as ONonNullableKeys } from "Object/NonNullableKeys";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Get the keys of **`L`** that are non-nullable
    @param L
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type NonNullableKeys<L extends List> = ONonNullableKeys<ObjectOf<L>>;
}
declare module "List/Nullable" {
    import { Key } from "Any/Key";
    import { Depth } from "Object/_Internal";
    import { List } from "List/List";
    import { Update } from "Object/Update";
    import { x } from "Any/x";
    /**
    Make some entries of **`L`** nullable (deeply or not)
    @param L to make nullable
    @param K (?=`Key`) to choose fields
    @param depth (?=`'flat'`) to do it deeply
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Nullable<L extends List, K extends Key = Key, depth extends Depth = 'flat'> = Update<L, K, x | null | undefined, depth>;
}
declare module "List/NullableKeys" {
    import { NullableKeys as ONullableKeys } from "Object/NullableKeys";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Get the keys of **`L`** that are nullable
    @param L
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type NullableKeys<L extends List> = ONullableKeys<ObjectOf<L>>;
}
declare module "List/Optional" {
    import { OptionalPart } from "Object/Optional";
    import { Depth } from "Object/_Internal";
    import { List } from "List/List";
    /**
    Make **`L`** optional (deeply or not)
    @param L to make optional
    @param depth (?=`'flat'`) to do it deeply
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Optional<L extends List, depth extends Depth = 'flat'> = OptionalPart<L, depth>;
}
declare module "List/OptionalKeys" {
    import { OptionalKeys as OOptionalKeys } from "Object/OptionalKeys";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Get the keys of **`L`** that are optional
    @param L
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type OptionalKeys<L extends List> = OOptionalKeys<ObjectOf<L>>;
}
declare module "List/Overwrite" {
    import { Overwrite as OOverwrite } from "Object/Overwrite";
    import { Cast } from "Any/Cast";
    import { List } from "List/List";
    /**
    Update the entries of **`L`** with the ones of **`L1`**
    @param L to update
    @param L1 to update with
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Overwrite<L extends List, L1 extends object> = Cast<OOverwrite<L, L1>, List>;
}
declare module "List/Partial" {
    import { Partial as OPartial } from "Object/Partial";
    import { Depth } from "Object/_Internal";
    import { Cast } from "Any/Cast";
    import { List } from "List/List";
    /**
    Make all fields of **`O`** optional (deeply or not)
    @param L to make optional
    @param depth (?=`'flat'`) to do it deeply
    @returns [[List]]
    @example
    ```ts
    import {O} from 'ts-toolbelt'
    
    type L = [1, 2, 3, [4, [5]]]
    
    type test0 = O.Partial<L>
    type test1 = O.Partial<L, 'deep'>
    ```
    */
    export type Partial<L extends List, depth extends Depth = 'flat'> = Cast<OPartial<L, depth>, List>;
}
declare module "List/PatchAll" {
    import { PatchAll as OPatchAll } from "Object/PatchAll";
    import { List } from "List/List";
    import { Depth } from "Object/_Internal";
    import { BuiltInObject } from "Misc/BuiltInObject";
    /**
    [[Patch]] a list of [[List]]s into **`L`**. Patches from left to right, first
    items get completed by the next ones (last-in completes).
    @param O to start with
    @param Os to patch
    @param depth (?=`'flat'`) to do it deeply
    @param noMerge (?=`BuiltinObject`) types not to merge
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type PatchAll<O extends List, Ls extends List<List>, depth extends Depth = 'flat', noMerge extends any = BuiltInObject> = OPatchAll<O, Ls, depth, 0, noMerge>;
}
declare module "List/Path" {
    import { Path as OPath } from "Object/Path";
    import { Key } from "Any/Key";
    import { List } from "List/List";
    /**
    Get in **`L`** the type of nested properties
    @param L to be inspected
    @param Path to be followed
    @returns **`any`**
    @example
    ```ts
    ```
    */
    export type Path<L extends List, Path extends List<Key>> = OPath<L, Path>;
}
declare module "List/Paths" {
    import { Paths as OPaths } from "Object/Paths";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Get all the possible paths of **`L`**
    (⚠️ this won't work with circular-refs)
    @param L to be inspected
    @returns **`string[]`**
    @example
    ```ts
    ```
    */
    export type Paths<L extends List> = OPaths<ObjectOf<L>>;
}
declare module "List/PathValid" {
    import { PathValid as OPathValid } from "Object/PathValid";
    import { Key } from "Any/Key";
    import { List } from "List/List";
    /**
    Replaces invalid parts of a path with `never`
    @param L to be inspected
    @param Path to be validated
    @returns **`Index[]`**
    @example
    ```ts
    import {A, L, O} from 'ts-toolbelt'
    
    // Get a property in an array `t` at any depth with `path`
    // `A.Cast<P, L.PathValid<L, P>>` makes sure `path` is valid
    const getAt = <
    L extends L.List,
    P extends L.List<A.Index>
    >(t: L, path: A.Cast<P, L.PathValid<L, P>>): L.Path<L, P> => {
        let valueAt = t
    
        for (const p of path)
            valueAt = valueAt[p]
    
        return valueAt as any
    }
    
    const test0 = getAt([[[1]]] as const, [0, 0] as const) // [1]
    const test1 = getAt([[[1]]] as const, [1] as const)    // error
    ```
    */
    export type PathValid<L extends List, Path extends List<Key>> = OPathValid<L, Path>;
}
declare module "List/Pop" {
    import { _Omit } from "List/Omit";
    import { List } from "List/List";
    import { LastIndex } from "List/LastIndex";
    import { Naked } from "List/_Internal";
    /**
    @hidden
    */
    export type _Pop<L extends List> = _Omit<L, LastIndex<Naked<L>, 's'>>;
    /**
    Remove the last element out of **`L`**
    @param L to remove from
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Pop<L extends List> = L extends unknown ? _Pop<L> : never;
}
declare module "List/Readonly" {
    import { Depth } from "Object/_Internal";
    import { ReadonlyPart } from "Object/Readonly";
    import { List } from "List/List";
    /**
    Make **`L`** readonly (deeply or not)
    @param L to make readonly
    @param depth (?=`'flat'`) to do it deeply
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Readonly<L extends List, depth extends Depth = 'flat'> = ReadonlyPart<L, depth>;
}
declare module "List/ReadonlyKeys" {
    import { ReadonlyKeys as OReadonlyKeys } from "Object/ReadonlyKeys";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Get the keys of **`L`** that are readonly
    @param L
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type ReadonlyKeys<L extends List> = OReadonlyKeys<ObjectOf<L>>;
}
declare module "List/Remove" {
    import { Number } from "Number/Number";
    import { KeySet } from "List/KeySet";
    import { Omit } from "List/Omit";
    import { List } from "List/List";
    /**
    Remove out of **`L`** a range of entries
    @param L to remove from
    @param From to start from
    @param To to end with
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Remove<L extends List, From extends Number, To extends Number> = Omit<L, KeySet<From, To>>;
}
declare module "List/Replace" {
    import { Replace as OReplace } from "Object/Replace";
    import { Match } from "Any/_Internal";
    import { Cast } from "Any/Cast";
    import { List } from "List/List";
    /**
    Update with **`A`** the entries of **`L`** that match **`M`**
    @param O to update
    @param M to select fields
    @param A to update with
    @param match (?=`'default'`) to change precision
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Replace<L extends List, M extends any, A extends any, match extends Match = 'default'> = Cast<OReplace<L, M, A, match>, List>;
}
declare module "List/Required" {
    import { Depth } from "Object/_Internal";
    import { RequiredPart } from "Object/Required";
    import { List } from "List/List";
    /**
    Make **`L`** required (deeply or not)
    @param L to make required
    @param depth (?=`'flat'`) to do it deeply
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Required<L extends List, depth extends Depth = 'flat'> = RequiredPart<L, depth>;
}
declare module "List/RequiredKeys" {
    import { RequiredKeys as ORequiredKeys } from "Object/RequiredKeys";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Get the keys of **`L`** that are readonly
    @param L
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type RequiredKeys<L extends List> = ORequiredKeys<ObjectOf<L>>;
}
declare module "List/Select" {
    import { Match } from "Any/_Internal";
    import { Select as OSelect } from "Object/Select";
    import { ListOf } from "Object/ListOf";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Extract the entries of **`L`** that match **`M`**
    @param L to extract from
    @param M to select entries
    @param match (?=`'default'`) to change precision
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Select<L extends List, M extends any, match extends Match = 'default'> = ListOf<OSelect<ObjectOf<L>, M, match>>;
}
declare module "List/SelectKeys" {
    import { Match } from "Any/_Internal";
    import { SelectKeys as OSelectKeys } from "Object/SelectKeys";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Get the keys of **`L`** which entries match **`M`**
    @param L to extract from
    @param M to select entries
    @param match (?=`'default'`) to change precision
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type SelectKeys<L extends List, M extends any, match extends Match = 'default'> = OSelectKeys<ObjectOf<L>, M, match>;
}
declare module "List/Shortest" {
    import { Exclude } from "Union/Exclude";
    import { List } from "List/List";
    import { Keys } from "List/Keys";
    /**
    Get the shortest [[List]] of **`L`** & **`L1`**
    (**`L`** has priority if both lengths are equal)
    @param L to compare length
    @param L1 to compare length
    @returns **`L`** or **`L1`**
    @example
    ```ts
    ```
    */
    export type Shortest<L extends List, L1 extends List> = [
        Exclude<Keys<L>, Keys<L1>>
    ] extends [never] ? L : L1;
}
declare module "List/Undefinable" {
    import { Key } from "Any/Key";
    import { Depth } from "Object/_Internal";
    import { List } from "List/List";
    import { Update } from "Object/Update";
    import { x } from "Any/x";
    /**
    Make some entries of **`L`** not **`undefined`** (deeply or not)
    @param L to make non nullable
    @param K (?=`Key`) to choose fields
    @param depth (?=`'flat'`) to do it deeply
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Undefinable<L extends List, K extends Key = Key, depth extends Depth = 'flat'> = Update<L, K, x | undefined, depth>;
}
declare module "List/UndefinableKeys" {
    import { UndefinableKeys as OUndefinableKeys } from "Object/UndefinableKeys";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Get the keys of **`L`** that are **`undefined`**
    @param L
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type UndefinableKeys<L extends List> = OUndefinableKeys<ObjectOf<L>>;
}
declare module "List/Unionize" {
    import { Key } from "Any/Key";
    import { List } from "List/List";
    import { At } from "Object/At";
    import { Format } from "String/Format";
    /**
    Make the fields of **`L`** union the ones of **`L1`**
    @param L to union from
    @param L1 to union with
    @param K (?=`Key`) to do choose fields
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Unionize<L extends List, L1 extends List, K extends Key = Key> = {
        [P in keyof L]: P extends K ? L[P] | At<L1, P extends string ? Format<P, 'n'> : P> : L[P];
    } & {};
}
declare module "List/Writable" {
    import { Depth } from "Object/_Internal";
    import { WritablePart } from "Object/Writable";
    import { List } from "List/List";
    /**
    Make **`L`** writable (deeply or not)
    @param L to make writable
    @param depth (?=`'flat'`) to do it deeply
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Writable<L extends List, depth extends Depth = 'flat'> = WritablePart<L, depth>;
}
declare module "List/WritableKeys" {
    import { WritableKeys as OWritableKeys } from "Object/WritableKeys";
    import { ObjectOf } from "List/ObjectOf";
    import { List } from "List/List";
    /**
    Get the keys of **`L`** that are writable
    @param L
    @returns [[Key]]
    @example
    ```ts
    ```
    */
    export type WritableKeys<L extends List> = OWritableKeys<ObjectOf<L>>;
}
declare module "List/Zip" {
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Prepend } from "List/Prepend";
    import { Next } from "Iteration/Next";
    import { Length } from "List/Length";
    import { Pos } from "Iteration/Pos";
    import { _Reverse } from "List/Reverse";
    import { Cast } from "Any/Cast";
    import { List } from "List/List";
    import { Naked } from "List/_Internal";
    import { Extends } from "Any/Extends";
    /**
    @hidden
    */
    type __Zip<L extends List, L1 extends List, LN extends List = [], I extends Iteration = IterationOf<'0'>> = {
        0: __Zip<L, L1, Prepend<LN, [L[Pos<I>], L1[Pos<I>]]>, Next<I>>;
        1: _Reverse<LN>;
    }[Extends<Pos<I>, Length<L>>];
    /**
    @hidden
    */
    export type _Zip<L extends List, L1 extends List> = __Zip<Naked<L>, L1> extends infer X ? Cast<X, List> : never;
    /**
    Pair up the entries of **`L`** with **`L1`**
    @param L to pair up
    @param L1 to pair up with
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type Zip<L extends List, L1 extends List> = L extends unknown ? L1 extends unknown ? _Zip<L, L1> : never : never;
}
declare module "List/ZipObj" {
    import { Length } from "List/Length";
    import { Pos } from "Iteration/Pos";
    import { Next } from "Iteration/Next";
    import { IterationOf } from "Iteration/IterationOf";
    import { Iteration } from "Iteration/Iteration";
    import { Cast } from "Any/Cast";
    import { Record } from "Object/Record";
    import { Key } from "Any/Key";
    import { List } from "List/List";
    import { Naked } from "List/_Internal";
    import { Extends } from "Any/Extends";
    import { PatchFlat } from "Object/Patch";
    /**
    @hidden
    */
    type __ZipObj<LKeys extends List<Key>, LFields extends List, O extends object = {}, I extends Iteration = IterationOf<'0'>> = {
        0: __ZipObj<LKeys, LFields, PatchFlat<O, Record<LKeys[Pos<I>], LFields[Pos<I>]>>, Next<I>>;
        1: O;
    }[Extends<Pos<I>, Length<LKeys>>];
    /**
    @hidden
    */
    export type _ZipObj<LKeys extends List<Key>, LFields extends List> = __ZipObj<Naked<LKeys>, LFields> extends infer X ? Cast<X, object> : never;
    /**
    Create an [[Object]] from [[List]]s of keys & fields
    @param LKeys its keys
    @param LFields its fields
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type ZipObj<LKeys extends List<Key>, LFields extends List> = LKeys extends unknown ? LFields extends unknown ? _ZipObj<LKeys, LFields> : never : never;
}
declare module "List/Merge" {
    import { Merge as OMerge } from "Object/Merge";
    import { List } from "List/List";
    import { Depth } from "Object/_Internal";
    import { BuiltInObject } from "Misc/BuiltInObject";
    /**
    Accurately merge the fields of **`L`** with the ones of **`L1`**. It is
    equivalent to the spread operator in JavaScript. [[Union]]s and [[Optional]]
    fields will be handled gracefully.
    
    (⚠️ needs `--strictNullChecks` enabled)
    @param L to complete
    @param L1 to copy from
    @param depth (?=`'flat'`) to do it deeply
    @param noMerge (?=`BuiltinObject`) types not to merge
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Merge<L extends List, L1 extends List, depth extends Depth = 'flat', noMerge extends any = BuiltInObject> = OMerge<L, L1, depth, 0, noMerge>;
}
declare module "List/_api" {
    /** @ignore */ /** */
    export { Append } from "List/Append";
    export { Assign } from "List/Assign";
    export { At } from "List/At";
    export { AtLeast } from "List/AtLeast";
    export { Compulsory } from "List/Compulsory";
    export { CompulsoryKeys } from "List/CompulsoryKeys";
    export { Concat } from "List/Concat";
    export { Diff } from "List/Diff";
    export { Drop } from "List/Drop";
    export { Either } from "List/Either";
    export { Exclude } from "List/Exclude";
    export { ExcludeKeys } from "List/ExcludeKeys";
    export { Extract } from "List/Extract";
    export { Filter } from "List/Filter";
    export { FilterKeys } from "List/FilterKeys";
    export { Flatten } from "List/Flatten";
    export { Group } from "List/Group";
    export { Has } from "List/Has";
    export { HasPath } from "List/HasPath";
    export { Head } from "List/Head";
    export { Includes } from "List/Includes";
    export { Intersect } from "List/Intersect";
    export { IntersectKeys } from "List/IntersectKeys";
    export { Keys } from "List/Keys";
    export { KeySet } from "List/KeySet";
    export { Last } from "List/Last";
    export { LastIndex } from "List/LastIndex";
    export { Length } from "List/Length";
    export { List } from "List/List";
    export { Longest } from "List/Longest";
    export { Patch as Merge } from "List/Patch";
    export { MergeAll } from "List/MergeAll";
    export { Modify } from "List/Modify";
    export { NonNullable } from "List/NonNullable";
    export { NonNullableKeys } from "List/NonNullableKeys";
    export { Nullable } from "List/Nullable";
    export { NullableKeys } from "List/NullableKeys";
    export { ObjectOf } from "List/ObjectOf";
    export { Omit } from "List/Omit";
    export { Optional } from "List/Optional";
    export { OptionalKeys } from "List/OptionalKeys";
    export { Overwrite } from "List/Overwrite";
    export { Partial } from "List/Partial";
    export { Patch } from "List/Patch";
    export { PatchAll } from "List/PatchAll";
    export { Path } from "List/Path";
    export { Paths } from "List/Paths";
    export { PathValid } from "List/PathValid";
    export { Pick } from "List/Pick";
    export { Pop } from "List/Pop";
    export { Prepend } from "List/Prepend";
    export { Readonly } from "List/Readonly";
    export { ReadonlyKeys } from "List/ReadonlyKeys";
    export { Remove } from "List/Remove";
    export { Repeat } from "List/Repeat";
    export { Replace } from "List/Replace";
    export { Required } from "List/Required";
    export { RequiredKeys } from "List/RequiredKeys";
    export { Reverse } from "List/Reverse";
    export { Select } from "List/Select";
    export { SelectKeys } from "List/SelectKeys";
    export { Shortest } from "List/Shortest";
    export { Tail } from "List/Tail";
    export { Take } from "List/Take";
    export { Undefinable } from "List/Undefinable";
    export { UndefinableKeys } from "List/UndefinableKeys";
    export { Unionize } from "List/Unionize";
    export { UnionOf } from "List/UnionOf";
    export { UnNest } from "List/UnNest";
    export { Update } from "List/Update";
    export { Writable } from "List/Writable";
    export { WritableKeys } from "List/WritableKeys";
    export { Zip } from "List/Zip";
    export { ZipObj } from "List/ZipObj";
    export { Merge as MergeUp } from "List/Merge";
    export { Assign as AssignUp } from "List/Assign";
    export { PatchAll as Compact } from "List/PatchAll";
    export { MergeAll as CompactUp } from "List/MergeAll";
}
declare module "Union/Diff" {
    import { Exclude } from "Union/Exclude";
    import { Union } from "Union/Union";
    /**
    Get an [[Union]] that is the difference between **`U1`** & **`U2`**
    @param U1 to check differences with
    @param U2 to check differences against
    @returns [[Union]]
    @example
    ```ts
    ```
    */
    export type Diff<U1 extends Union, U2 extends Union> = Exclude<U1, U2> | Exclude<U2, U1>;
}
declare module "Union/Filter" {
    import { Union } from "Union/Union";
    import { Match } from "Any/_Internal";
    import { Is } from "Any/Is";
    /**
    Remove **`M`** out of **`U`**
    @param U to remove from
    @param M to remove out
    @returns [[Union]]
    @example
    ```ts
    ```
    */
    export type Filter<U extends Union, M extends Union, match extends Match = 'default'> = U extends unknown ? Is<U, M, match> extends 1 ? never : U : never;
}
declare module "Union/Last" {
    import { IntersectOf } from "Union/IntersectOf";
    import { Union } from "Union/Union";
    /**
    Get the last item within an [[Union]]
    (⚠️ it might not preserve order)
    @param U
    @returns **any**
    @example
    ```ts
    ```
    */
    export type Last<U extends Union> = IntersectOf<U extends unknown ? (x: U) => void : never> extends (x: infer P) => void ? P : never;
}
declare module "Union/Merge" {
    import { At } from "Object/At";
    import { Overwrite } from "Object/Overwrite";
    import { ComputeRaw } from "Any/Compute";
    import { IntersectOf } from "Union/IntersectOf";
    import { Strict } from "Union/Strict";
    /**
    @hidden
    */
    type _Merge<U extends object> = IntersectOf<Overwrite<U, {
        [K in keyof U]-?: At<U, K>;
    }>>;
    /**
    Merge a [[Union]] of [[Object]]s into a single one
    @param U to merge
    @returns [[Object]]
    @example
    ```ts
    ```
    */
    export type Merge<U extends object> = ComputeRaw<_Merge<Strict<U>>>;
}
declare module "Union/Pop" {
    import { Exclude } from "Union/Exclude";
    import { Last } from "Union/Last";
    import { Union } from "Union/Union";
    /**
    Remove an item out of **`U`**
    (⚠️ it might not preserve order)
    @param U to remove from
    @returns [[Union]]
    @example
    ```ts
    ```
    */
    export type Pop<U extends Union> = Exclude<U, Last<U>>;
}
declare module "Union/Select" {
    import { Union } from "Union/Union";
    import { Is } from "Any/Is";
    import { Match } from "Any/_Internal";
    /**
    Extract the part of **`U`** that matches **`M`**
    @param U to extract from
    @param M to select with
    @returns [[Union]]
    @example
    ```ts
    ```
    */
    export type Select<U extends Union, M extends any, match extends Match = 'default'> = U extends unknown ? Is<U, M, match> extends 1 ? U : never : never;
}
declare module "Union/ListOf" {
    import { Last } from "Union/Last";
    import { Prepend } from "List/Prepend";
    import { Exclude } from "Union/Exclude";
    import { List } from "List/List";
    import { Union } from "Union/Union";
    import { Cast } from "Any/Cast";
    import { Extends } from "Any/Extends";
    /**
    @hidden
    */
    type _ListOf<U, LN extends List = [], LastU = Last<U>> = {
        0: _ListOf<Exclude<U, LastU>, Prepend<LN, LastU>>;
        1: LN;
    }[Extends<[U], [never]>];
    /**
    Transform a [[Union]] into a [[List]]
    (⚠️ it might not preserve order)
    @param U to transform
    @returns [[List]]
    @example
    ```ts
    ```
    */
    export type ListOf<U extends Union> = _ListOf<U> extends infer X ? Cast<X, List> : never;
}
declare module "Union/_api" {
    /** @ignore */ /** */
    export { Diff } from "Union/Diff";
    export { Exclude } from "Union/Exclude";
    export { Filter } from "Union/Filter";
    export { Has } from "Union/Has";
    export { Intersect } from "Union/Intersect";
    export { IntersectOf } from "Union/IntersectOf";
    export { Keys } from "Union/Keys";
    export { Last } from "Union/Last";
    export { Merge } from "Union/Merge";
    export { NonNullable } from "Union/NonNullable";
    export { Nullable } from "Union/Nullable";
    export { Pop } from "Union/Pop";
    export { Replace } from "Union/Replace";
    export { Select } from "Union/Select";
    export { Strict } from "Union/Strict";
    export { ListOf } from "Union/ListOf";
    export { Union } from "Union/Union";
}
declare module "ts-toolbelt" {
    /** @ignore */ /** */
    import * as Test from "Test";
    import * as A from "Any/_api";
    import * as B from "Boolean/_api";
    import * as C from "Class/_api";
    import * as Community from "Community/_api";
    import * as F from "Function/_api";
    import * as I from "Iteration/_api";
    import * as M from "Misc/_api";
    import * as N from "Number/_api";
    import * as O from "Object/_api";
    import * as S from "String/_api";
    import * as T from "List/_api";
    import * as L from "List/_api";
    import * as U from "Union/_api";
    import * as Any from "Any/_api";
    import * as Boolean from "Boolean/_api";
    import * as Class from "Class/_api";
    import * as Function from "Function/_api";
    import * as Iteration from "Iteration/_api";
    import * as Misc from "Misc/_api";
    import * as Number from "Number/_api";
    import * as Object from "Object/_api";
    import * as String from "String/_api";
    import * as Tuple from "List/_api";
    import * as List from "List/_api";
    import * as Union from "Union/_api";
    export { Test, A, Any, B, Boolean, C, Class, Community, F, Function, I, Iteration, L, List, M, Misc, N, Number, O, Object, S, String, T, Tuple, U, Union, };
}
